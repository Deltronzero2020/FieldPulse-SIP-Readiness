#Requires -Version 5.1
<#
.SYNOPSIS
    FieldPulse Engage  -  SIP Phone Registration Readiness Check (GUI)
.DESCRIPTION
    Runs a network readiness check for FieldPulse SIP phone onboarding.
    Displays results in a friendly GUI window, then sends the report to
    the FieldPulse team automatically.
.NOTES
    Run as Administrator for full firewall diagnostics and auto-fix.
    Right-click > "Run with PowerShell" and accept the UAC prompt.
#>

Set-StrictMode -Version Latest

# Require TLS 1.2 for all outbound HTTPS connections (Finding 8.1)
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12

# -------------------------------------------------------------
# WEBHOOK CONFIGURATION
# -------------------------------------------------------------
# SECURITY: Before deploying, ensure WEBHOOK_SECRET matches the backend.
# Generate a new secret with: (New-Guid).Guid
# The backend (Apps Script) must be configured with the SAME secret.
# Never commit the real secret to version control.
# -------------------------------------------------------------
# Google Apps Script Web App URL (already deployed).
$WEBHOOK_URL    = "https://script.google.com/macros/s/AKfycbxJkyq08JDa2m74AU7wzWeP66n8SPyV-NAMgazGnGVkJSSVkerhj1Wqf_dsoaJNHTpX/exec"

# Shared HMAC secret — must match WEBHOOK_SECRET in the Apps Script backend.
# IMPORTANT: Replace 'REPLACE_WITH_YOUR_SECRET' with your actual UUID before signing.
$WEBHOOK_SECRET = "b9998be9-a908-435e-a4a5-51ff793eb71b"


# -------------------------------------------------------------
# REQUIRED IPs (from FieldPulse checklist)
# -------------------------------------------------------------
$HTTP_IPS = @('75.98.50.201','207.254.80.55','70.42.44.55','75.98.50.55','216.24.144.55')
$SIP_IPS  = @('54.172.60.0','54.172.60.1','54.172.60.2','54.172.60.3',
               '54.244.51.0','54.244.51.1','54.244.51.2','54.244.51.3')
$RTP_SAMPLE_IPS = @('168.86.128.1','168.86.150.1','168.86.191.1')

# -------------------------------------------------------------
# TIMEOUTS & LIMITS
# -------------------------------------------------------------
$TCP_PROBE_TIMEOUT_MS   = 1500    # Timeout for parallel TCP connectivity probes
$HTTP_REQUEST_TIMEOUT_S = 20      # Timeout for webhook HTTP request
$PING_COUNT             = 5       # Number of ICMP pings for latency test
$PING_TIMEOUT_MS        = 2000    # Timeout per ping
$MAX_LATENCY_GOOD_MS    = 100     # RTT threshold for PASS
$MAX_LATENCY_WARN_MS    = 150     # RTT threshold for WARN (above = FAIL)
$MAX_JITTER_GOOD_MS     = 20      # Jitter threshold for PASS
$MAX_JITTER_WARN_MS     = 30      # Jitter threshold for WARN (above = FAIL)
$MAX_CSV_SIZE_BYTES     = 204800  # 200 KB limit for phone CSV uploads
$MAX_CUSTOMER_NAME_LEN  = 100     # Max length for customer name field
$MAX_ATTENDEE_NAME_LEN  = 80      # Max length for attendee name
$MAX_ATTENDEE_EMAIL_LEN = 120     # Max length for attendee email

# -------------------------------------------------------------
# LOAD WINFORMS
# -------------------------------------------------------------
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# -------------------------------------------------------------
# COLORS & FONTS
# -------------------------------------------------------------
$clrBlue    = [System.Drawing.ColorTranslator]::FromHtml('#0062CC')
$clrBlueSub = [System.Drawing.ColorTranslator]::FromHtml('#A8C8F0')
$clrGreen   = [System.Drawing.ColorTranslator]::FromHtml('#1A7F37')
$clrRed     = [System.Drawing.ColorTranslator]::FromHtml('#CF222E')
$clrOrange  = [System.Drawing.ColorTranslator]::FromHtml('#9A6700')
$clrGray    = [System.Drawing.ColorTranslator]::FromHtml('#57606A')
$clrBg      = [System.Drawing.Color]::White
$clrRowAlt  = [System.Drawing.ColorTranslator]::FromHtml('#F6F8FA')
$clrBorder  = [System.Drawing.ColorTranslator]::FromHtml('#D0D7DE')

$fontTitle  = New-Object System.Drawing.Font('Segoe UI', 16, [System.Drawing.FontStyle]::Bold)
$fontSub    = New-Object System.Drawing.Font('Segoe UI', 9)
$fontMeta   = New-Object System.Drawing.Font('Segoe UI', 9)
$fontResult = New-Object System.Drawing.Font('Consolas', 9)
$fontBtn    = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
$fontStatus = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Italic)

# -------------------------------------------------------------
# SHARED STATE
# -------------------------------------------------------------
$script:results     = [System.Collections.Generic.List[hashtable]]::new()
$script:reportLines = [System.Collections.Generic.List[string]]::new()
$script:publicIP    = ''
$script:localIP     = ''
$script:gateway     = ''
$script:checksRan   = $false

# -------------------------------------------------------------
# HELPERS
# -------------------------------------------------------------
function Test-PortTCP {
    param([string]$IP, [int]$Port, [int]$TimeoutMs = 3000)
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $ar  = $tcp.BeginConnect($IP, $Port, $null, $null)
        $ok  = $ar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        $tcp.Close()
        return $ok
    } catch { return $false }
}

function Add-ResultRow {
    param(
        [string]$Icon,
        [string]$Category,
        [string]$Detail,
        [string]$Status   # PASS | FAIL | WARN | INFO
    )
    $script:results.Add(@{
        Icon     = $Icon
        Category = $Category
        Detail   = $Detail
        Status   = $Status
    })
    $script:reportLines.Add("[$($Status.PadRight(4))] $Category  -  $Detail")
}

function Append-ResultBox {
    param(
        [System.Windows.Forms.RichTextBox]$Box,
        [string]$Icon,
        [string]$Category,
        [string]$Detail,
        [string]$Status
    )
    $clr = switch ($Status) {
        'PASS' { $clrGreen  }
        'FAIL' { $clrRed    }
        'WARN' { $clrOrange }
        default{ $clrGray   }
    }
    $line = "$Icon  $Category"
    $Box.SelectionColor = $clr
    $Box.SelectionFont  = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $Box.AppendText($line)
    $Box.SelectionColor = $clrGray
    $Box.SelectionFont  = $fontMeta
    $Box.AppendText("   -   $Detail`n")
    [System.Windows.Forms.Application]::DoEvents()
}

function Set-Status {
    param($Label, $ProgressBar, [string]$Text, [int]$Value = -1)
    $Label.Text = $Text
    if ($Value -ge 0) { $ProgressBar.Value = [Math]::Min($Value, $ProgressBar.Maximum) }
    [System.Windows.Forms.Application]::DoEvents()
}

# -------------------------------------------------------------
# MAIN FORM
# -------------------------------------------------------------
$form                  = New-Object System.Windows.Forms.Form
$form.Text             = 'FieldPulse SIP Readiness Check'
$form.Size             = New-Object System.Drawing.Size(780, 680)
$form.MinimumSize      = New-Object System.Drawing.Size(780, 680)
$form.StartPosition    = 'CenterScreen'
$form.BackColor        = $clrBg
$form.FormBorderStyle  = 'FixedDialog'
$form.MaximizeBox      = $false
$form.Icon             = [System.Drawing.SystemIcons]::Shield

# -- Header ----------------------------------------------------
$pnlHeader            = New-Object System.Windows.Forms.Panel
$pnlHeader.Dock       = 'Top'
$pnlHeader.Height     = 72
$pnlHeader.BackColor  = $clrBlue

$lblTitle             = New-Object System.Windows.Forms.Label
$lblTitle.Text        = 'FieldPulse Engage'
$lblTitle.Font        = $fontTitle
$lblTitle.ForeColor   = [System.Drawing.Color]::White
$lblTitle.Location    = New-Object System.Drawing.Point(18, 8)
$lblTitle.AutoSize    = $true

$lblSub               = New-Object System.Windows.Forms.Label
$lblSub.Text          = 'SIP Phone Registration Readiness Check'
$lblSub.Font          = $fontSub
$lblSub.ForeColor     = $clrBlueSub
$lblSub.Location      = New-Object System.Drawing.Point(20, 42)
$lblSub.AutoSize      = $true

$pnlHeader.Controls.AddRange(@($lblTitle, $lblSub))
$form.Controls.Add($pnlHeader)

# -- Machine info strip -----------------------------------------
$pnlMeta             = New-Object System.Windows.Forms.Panel
$pnlMeta.Location    = New-Object System.Drawing.Point(0, 72)
$pnlMeta.Size        = New-Object System.Drawing.Size(780, 32)
$pnlMeta.BackColor   = $clrRowAlt
$pnlMeta.BorderStyle = 'None'

$lblMeta             = New-Object System.Windows.Forms.Label
$lblMeta.Text        = "  Computer: $env:COMPUTERNAME   |   User: $env:USERNAME   |   Date: $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
$lblMeta.Font        = $fontMeta
$lblMeta.ForeColor   = $clrGray
$lblMeta.Dock        = 'Fill'
$lblMeta.TextAlign   = 'MiddleLeft'

$pnlMeta.Controls.Add($lblMeta)
$form.Controls.Add($pnlMeta)

# -- Customer name input ----------------------------------------
$pnlInput            = New-Object System.Windows.Forms.Panel
$pnlInput.Location   = New-Object System.Drawing.Point(0, 104)
$pnlInput.Size       = New-Object System.Drawing.Size(780, 48)
$pnlInput.BackColor  = $clrBg

$lblName             = New-Object System.Windows.Forms.Label
$lblName.Text        = 'Your company name:'
$lblName.Font        = $fontMeta
$lblName.ForeColor   = $clrGray
$lblName.Location    = New-Object System.Drawing.Point(18, 14)
$lblName.AutoSize    = $true

$txtName             = New-Object System.Windows.Forms.TextBox
$txtName.Location    = New-Object System.Drawing.Point(158, 11)
$txtName.Size        = New-Object System.Drawing.Size(300, 24)
$txtName.Font        = $fontMeta
$txtName.MaxLength       = 100

$pnlInput.Controls.AddRange(@($lblName, $txtName))
$form.Controls.Add($pnlInput)

# Separator
$sep1                = New-Object System.Windows.Forms.Panel
$sep1.Location       = New-Object System.Drawing.Point(0, 152)
$sep1.Size           = New-Object System.Drawing.Size(780, 1)
$sep1.BackColor      = $clrBorder
$form.Controls.Add($sep1)

# -- Results area -----------------------------------------------
$rtbResults               = New-Object System.Windows.Forms.RichTextBox
$rtbResults.Location      = New-Object System.Drawing.Point(12, 158)
$rtbResults.Size          = New-Object System.Drawing.Size(752, 358)
$rtbResults.Font          = $fontResult
$rtbResults.BackColor     = $clrBg
$rtbResults.BorderStyle   = 'FixedSingle'
$rtbResults.ReadOnly      = $true
$rtbResults.ScrollBars    = 'Vertical'
$rtbResults.Text          = "  Press  Run Checks  to begin.`n`n" +
                            "  This will test your network against FieldPulse's SIP requirements`n" +
                            "  and prepare a report for the FieldPulse team.`n`n" +
                            "  Enter your company name above, then click Run Checks."

$form.Controls.Add($rtbResults)

# -- Progress bar ------------------------------------------------
$progressBar              = New-Object System.Windows.Forms.ProgressBar
$progressBar.Location     = New-Object System.Drawing.Point(12, 524)
$progressBar.Size         = New-Object System.Drawing.Size(752, 18)
$progressBar.Minimum      = 0
$progressBar.Maximum      = 100
$progressBar.Value        = 0
$progressBar.Style        = 'Continuous'
$form.Controls.Add($progressBar)

# -- Status label ------------------------------------------------
$lblStatus                = New-Object System.Windows.Forms.Label
$lblStatus.Location       = New-Object System.Drawing.Point(12, 546)
$lblStatus.Size           = New-Object System.Drawing.Size(752, 20)
$lblStatus.Font           = $fontStatus
$lblStatus.ForeColor      = $clrGray
$lblStatus.Text           = 'Ready.'
$form.Controls.Add($lblStatus)

# Separator
$sep2                = New-Object System.Windows.Forms.Panel
$sep2.Location       = New-Object System.Drawing.Point(0, 570)
$sep2.Size           = New-Object System.Drawing.Size(780, 1)
$sep2.BackColor      = $clrBorder
$form.Controls.Add($sep2)

# -- Buttons -----------------------------------------------------
$btnRun               = New-Object System.Windows.Forms.Button
$btnRun.Text          = '>  Run Checks'
$btnRun.Font          = $fontBtn
$btnRun.Size          = New-Object System.Drawing.Size(160, 40)
$btnRun.Location      = New-Object System.Drawing.Point(12, 582)
$btnRun.BackColor     = $clrBlue
$btnRun.ForeColor     = [System.Drawing.Color]::White
$btnRun.FlatStyle     = 'Flat'
$btnRun.FlatAppearance.BorderSize = 0
$btnRun.Cursor        = 'Hand'

$btnSend              = New-Object System.Windows.Forms.Button
$btnSend.Text         = 'Email  Send to FieldPulse'
$btnSend.Font         = $fontBtn
$btnSend.Size         = New-Object System.Drawing.Size(200, 40)
$btnSend.Location     = New-Object System.Drawing.Point(184, 582)
$btnSend.BackColor    = $clrGreen
$btnSend.ForeColor    = [System.Drawing.Color]::White
$btnSend.FlatStyle    = 'Flat'
$btnSend.FlatAppearance.BorderSize = 0
$btnSend.Cursor       = 'Hand'
$btnSend.Enabled      = $false

$btnSave              = New-Object System.Windows.Forms.Button
$btnSave.Text         = 'Save  Save Report'
$btnSave.Font         = $fontBtn
$btnSave.Size         = New-Object System.Drawing.Size(160, 40)
$btnSave.Location     = New-Object System.Drawing.Point(396, 582)
$btnSave.BackColor    = $clrRowAlt
$btnSave.ForeColor    = $clrGray
$btnSave.FlatStyle    = 'Flat'
$btnSave.FlatAppearance.BorderColor = $clrBorder
$btnSave.Cursor       = 'Hand'
$btnSave.Enabled      = $false

$btnClose             = New-Object System.Windows.Forms.Button
$btnClose.Text        = 'Close'
$btnClose.Font        = $fontBtn
$btnClose.Size        = New-Object System.Drawing.Size(100, 40)
$btnClose.Location    = New-Object System.Drawing.Point(664, 582)
$btnClose.BackColor   = $clrRowAlt
$btnClose.ForeColor   = $clrGray
$btnClose.FlatStyle   = 'Flat'
$btnClose.FlatAppearance.BorderColor = $clrBorder
$btnClose.Cursor      = 'Hand'

$form.Controls.AddRange(@($btnRun, $btnSend, $btnSave, $btnClose))

# -------------------------------------------------------------
# RUN CHECKS LOGIC
# -------------------------------------------------------------
$btnRun.Add_Click({
    # Reset state
    $script:results.Clear()
    $script:reportLines.Clear()
    $script:checksRan = $false
    $rtbResults.Clear()
    $progressBar.Value = 0
    $btnSend.Enabled   = $false
    $btnSave.Enabled   = $false
    $btnRun.Enabled    = $false

    $customerName = if ($txtName.Text.Trim()) { $txtName.Text.Trim() } else { 'Unknown Customer' }

    # -- Section header helper ---------------------------------
    function Write-Section {
        param([string]$Title)
        $rtbResults.SelectionColor = $clrBlue
        $rtbResults.SelectionFont  = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
        $rtbResults.AppendText("`n  $Title`n")
        $rtbResults.SelectionColor = $clrBorder
        $rtbResults.SelectionFont  = $fontMeta
        $rtbResults.AppendText("  " + ("-" * 60) + "`n")
        $script:reportLines.Add("`n$Title")
        $script:reportLines.Add("-" * 60)
        [System.Windows.Forms.Application]::DoEvents()
    }

    # -- CHECK 1  -  Network adapter -----------------------------
    Set-Status $lblStatus $progressBar 'Checking network connection type...' 5
    Write-Section "1. NETWORK CONNECTION TYPE"

    $adapters  = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' }
    $wired     = $adapters | Where-Object { $_.PhysicalMediaType -match 'Ethernet|802.3' -or ($_.InterfaceDescription -match 'Ethernet|Gigabit' -and $_.InterfaceDescription -notmatch 'Virtual|Loopback|Wi-Fi|Wireless') }
    $wireless  = $adapters | Where-Object { $_.PhysicalMediaType -match 'Wi-Fi|Native 802.11|Wireless' -or $_.InterfaceDescription -match 'Wi-Fi|Wireless|WLAN' }

    if ($wired) {
        foreach ($a in $wired) {
            Append-ResultBox $rtbResults '[OK]' "Wired (Ethernet) adapter active" $a.Name 'PASS'
            Add-ResultRow '[OK]' "Wired adapter" $a.Name 'PASS'
        }
    } else {
        Append-ResultBox $rtbResults '[!]' "No wired adapter found" "Use Ethernet for SIP phones when possible" 'WARN'
        Add-ResultRow '[!]' "No wired adapter" "Wi-Fi only detected" 'WARN'
    }
    if ($wireless) {
        foreach ($a in $wireless) {
            Append-ResultBox $rtbResults '[i]' "Wi-Fi adapter active" "$($a.Name)  -  SIP phones should use wired" 'INFO'
            Add-ResultRow '[i]' "Wi-Fi active" $a.Name 'INFO'
        }
    }

    # Gather network addresses
    $ipConfig         = Get-NetIPConfiguration | Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } | Select-Object -First 1
    $script:localIP   = ($ipConfig.IPv4Address | Select-Object -First 1).IPAddress
    $script:gateway   = ($ipConfig.IPv4DefaultGateway | Select-Object -First 1).NextHop
    try {
        $script:publicIP  = (Invoke-RestMethod 'https://api.ipify.org?format=json' -TimeoutSec 3).ip
    } catch { $script:publicIP = 'Could not determine' }

    Append-ResultBox $rtbResults '[i]' "Local IP" "$($script:localIP)   Gateway: $($script:gateway)   Public IP: $($script:publicIP)" 'INFO'

    # -- CHECK 2  -  IP Connectivity -----------------------------
    Set-Status $lblStatus $progressBar 'Testing connectivity to FieldPulse IPs...' 15
    Write-Section "2. CONNECTIVITY TO FIELDPULSE IPs"

    $allReach    = $true

    # -- Start all TCP probes in parallel (batch async) --
    Set-Status $lblStatus $progressBar 'Testing connectivity to all FieldPulse IPs in parallel...' 18
    $allProbes = [System.Collections.Generic.List[hashtable]]::new()

    foreach ($ip in $HTTP_IPS) {
        foreach ($port in @(80, 443)) {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $ar  = $null
            try { $ar = $tcp.BeginConnect($ip, $port, $null, $null) } catch { }
            $allProbes.Add(@{ IP=$ip; Port=$port; Type='HTTP'; Client=$tcp; AR=$ar })
        }
    }
    foreach ($ip in $SIP_IPS) {
        foreach ($port in @(5060, 5061)) {
            $tcp = New-Object System.Net.Sockets.TcpClient
            $ar  = $null
            try { $ar = $tcp.BeginConnect($ip, $port, $null, $null) } catch { }
            $allProbes.Add(@{ IP=$ip; Port=$port; Type='SIP'; Client=$tcp; AR=$ar })
        }
    }
    foreach ($ip in $RTP_SAMPLE_IPS) {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $ar  = $null
        try { $ar = $tcp.BeginConnect($ip, 10000, $null, $null) } catch { }
        $allProbes.Add(@{ IP=$ip; Port=10000; Type='RTP'; Client=$tcp; AR=$ar })
    }

    # Single wait covers all probes simultaneously
    Start-Sleep -Milliseconds $TCP_PROBE_TIMEOUT_MS

    # Collect results into cache for reuse in later checks
    # Use try/finally to ensure proper disposal of TCP resources
    $script:tcpCache = @{}
    foreach ($p in $allProbes) {
        $ok = $false
        try {
            if ($p.AR) {
                $ok = $p.AR.AsyncWaitHandle.WaitOne(0, $false)
            }
            $script:tcpCache["$($p.IP):$($p.Port)"] = $ok
        }
        catch { $script:tcpCache["$($p.IP):$($p.Port)"] = $false }
        finally {
            # Dispose resources in correct order
            if ($p.AR -and $p.AR.AsyncWaitHandle) {
                try { $p.AR.AsyncWaitHandle.Close() } catch { }
            }
            if ($p.Client) {
                try { $p.Client.Close(); $p.Client.Dispose() } catch { }
            }
        }
    }
    Set-Status $lblStatus $progressBar 'Processing connectivity results...' 40

    # Report HTTP IPs
    foreach ($ip in $HTTP_IPS) {
        $ok = $script:tcpCache["${ip}:80"] -or $script:tcpCache["${ip}:443"]
        if ($ok) {
            Append-ResultBox $rtbResults '[OK]' "HTTP IP reachable" "$ip (port 80/443)" 'PASS'
            Add-ResultRow '[OK]' "HTTP IP $ip" "Reachable" 'PASS'
        } else {
            Append-ResultBox $rtbResults '[X]' "HTTP IP BLOCKED" "$ip  -  cannot reach port 80 or 443" 'FAIL'
            Add-ResultRow '[X]' "HTTP IP $ip" "BLOCKED  -  cannot reach port 80/443" 'FAIL'
            $allReach = $false
        }
    }

    # Report SIP IPs
    foreach ($ip in $SIP_IPS) {
        $ok5060 = $script:tcpCache["${ip}:5060"]
        $ok5061 = $script:tcpCache["${ip}:5061"]
        if ($ok5060 -or $ok5061) {
            Append-ResultBox $rtbResults '[OK]' "SIP IP reachable" "$ip (5060: $ok5060  5061/TLS: $ok5061)" 'PASS'
            Add-ResultRow '[OK]' "SIP IP $ip" "Reachable on SIP ports" 'PASS'
        } else {
            Append-ResultBox $rtbResults '[X]' "SIP IP BLOCKED" "$ip  -  port 5060 and 5061 unreachable" 'FAIL'
            Add-ResultRow '[X]' "SIP IP $ip" "BLOCKED on 5060 and 5061" 'FAIL'
            $allReach = $false
        }
    }

    # Report RTP IPs
    foreach ($ip in $RTP_SAMPLE_IPS) {
        $ok = $script:tcpCache["${ip}:10000"]
        if ($ok) {
            Append-ResultBox $rtbResults '[OK]' "RTP media IP reachable" $ip 'PASS'
            Add-ResultRow '[OK]' "RTP IP $ip" "Reachable" 'PASS'
        } else {
            Append-ResultBox $rtbResults '[!]' "RTP media IP inconclusive" "$ip  -  RTP uses UDP; TCP probe may fail even if audio works" 'WARN'
            Add-ResultRow '[!]' "RTP IP $ip" "TCP probe failed (RTP is UDP  -  verify during onboarding call)" 'WARN'
        }
    }

    if ($allReach) {
        Append-ResultBox $rtbResults '[OK]' "All required IPs reachable" "Your network can reach FieldPulse servers" 'PASS'
    } else {
        Append-ResultBox $rtbResults '[X]' "One or more IPs blocked" "Update your router/firewall  -  see checklist for IP list" 'FAIL'
    }

    # -- CHECK 2b  -  Latency & Jitter ---------------------------
    Set-Status $lblStatus $progressBar 'Testing network latency and jitter...' 52
    Write-Section "2b. LATENCY & JITTER"

    # SIP thresholds: avg RTT <=100ms good, <=150ms marginal, >150ms fail
    #                 jitter (max-min) <=20ms good, <=30ms marginal, >30ms fail
    function Test-Latency {
        param([string]$Target, [string]$Label)
        try {
            $pings = Test-Connection -ComputerName $Target -Count 5 -ErrorAction SilentlyContinue
            $rtts  = @($pings | Where-Object { $_ -and $_.ResponseTime -gt 0 } |
                       ForEach-Object { $_.ResponseTime })
            if ($rtts.Count -lt 3) {
                Append-ResultBox $rtbResults '[!]' "Latency inconclusive  -  $Label" "Fewer than 3 ICMP replies  -  firewall may block ping" 'WARN'
                Add-ResultRow '[!]' "Latency ($Label)" "Inconclusive  -  ICMP may be blocked" 'WARN'
                return
            }
            $avg    = [math]::Round(($rtts | Measure-Object -Average).Average, 1)
            $jitter = ($rtts | Measure-Object -Maximum).Maximum -
                      ($rtts | Measure-Object -Minimum).Minimum
            $lost   = 5 - $rtts.Count
            $detail = "Avg RTT: ${avg}ms   Jitter: ${jitter}ms   Packet loss: $lost/10"

            if ($avg -le $MAX_LATENCY_GOOD_MS -and $jitter -le $MAX_JITTER_GOOD_MS) {
                Append-ResultBox $rtbResults '[OK]' "Latency good  -  $Label" $detail 'PASS'
                Add-ResultRow '[OK]' "Latency $Label" $detail 'PASS'
            } elseif ($avg -le $MAX_LATENCY_WARN_MS -and $jitter -le $MAX_JITTER_WARN_MS) {
                Append-ResultBox $rtbResults '[!]' "Latency marginal  -  $Label" "$detail  -  may cause audio issues under load" 'WARN'
                Add-ResultRow '[!]' "Latency $Label" "$detail  -  marginal for SIP" 'WARN'
            } else {
                Append-ResultBox $rtbResults '[X]' "Latency too high  -  $Label" "$detail  -  SIP calls will have audio problems" 'FAIL'
                Add-ResultRow '[X]' "Latency $Label" "$detail  -  exceeds SIP thresholds" 'FAIL'
            }
            $script:reportLines.Add("Latency $Label : $detail")
        } catch {
            Append-ResultBox $rtbResults '[!]' "Latency test failed  -  $Label" "ICMP may be blocked by firewall or host" 'WARN'
            Add-ResultRow '[!]' "Latency $Label" "Could not test  -  ICMP blocked" 'WARN'
        }
    }

    if ($script:gateway) { Test-Latency $script:gateway 'Gateway' }
    Test-Latency $SIP_IPS[0] 'FieldPulse SIP'

    # -- CHECK 3  -  Router & Gateway Configuration --------------
    Set-Status $lblStatus $progressBar 'Detecting router and testing gateway configuration...' 55
    Write-Section "3. ROUTER & GATEWAY CONFIGURATION"

    # --- 3a. Detect router brand from admin page HTTP response ---
    $routerBrand    = 'Unknown'
    $routerAdminUrl = "http://$($script:gateway)"
    try {
        $adminResp   = Invoke-WebRequest -Uri $routerAdminUrl -TimeoutSec 2 -UseBasicParsing -ErrorAction Stop
        $probeText   = ($adminResp.Content + ' ' + ($adminResp.Headers['Server'] -join ' ')).ToLower()
        $routerBrand = switch -Regex ($probeText) {
            'ubiquiti|unifi|edgeos|edgerouter' { 'Ubiquiti';            break }
            'cisco meraki|meraki'              { 'Cisco Meraki';        break }
            'cisco'                            { 'Cisco';               break }
            'netgear'                          { 'Netgear';             break }
            'asus'                             { 'ASUS';                break }
            'tp-link|tplink'                   { 'TP-Link';             break }
            'linksys'                          { 'Linksys';             break }
            'fortinet|fortigate'               { 'Fortinet FortiGate';  break }
            'sonicwall'                        { 'SonicWall';           break }
            'mikrotik|routeros'                { 'MikroTik';            break }
            'pfsense'                          { 'pfSense';             break }
            'opnsense'                         { 'OPNsense';            break }
            'ruckus'                           { 'Ruckus';              break }
            'watchguard'                       { 'WatchGuard';          break }
            default                            { 'Unknown';             break }
        }
    } catch { }

    Append-ResultBox $rtbResults '[i]' "Gateway / Router detected" "$($script:gateway)   Brand: $routerBrand" 'INFO'
    Add-ResultRow '[i]' "Gateway" "$($script:gateway)  -  Brand: $routerBrand" 'INFO'

    # --- 3b. SIP port reachability (reuse cached results from parallel Check 2 probes) ---
    $sip60ok = $script:tcpCache["$($SIP_IPS[0]):5060"]
    $sip61ok = $script:tcpCache["$($SIP_IPS[0]):5061"]
    if ($sip60ok -or $sip61ok) {
        Append-ResultBox $rtbResults '[OK]' "SIP signaling ports reachable" "5060: $sip60ok   5061/TLS: $sip61ok  -  traffic is passing through router" 'PASS'
        Add-ResultRow '[OK]' "SIP ports at router" "5060: $sip60ok  5061: $sip61ok" 'PASS'
    } else {
        Append-ResultBox $rtbResults '[X]' "SIP ports BLOCKED at router" "Ports 5060 and 5061 unreachable  -  router firewall must allow outbound SIP" 'FAIL'
        Add-ResultRow '[X]' "SIP ports at router" "BLOCKED  -  open TCP/UDP 5060 and 5061 outbound in router" 'FAIL'
    }

    # --- 3c. Brand-specific SIP ALG disable steps ---
    $sipAlgSteps = switch ($routerBrand) {
        'Ubiquiti'           { "Config > Routing & Firewall > ALG > uncheck SIP" }
        'Cisco Meraki'       { "Security & SD-WAN > Firewall > uncheck SIP ALG" }
        'Cisco'              { "Firewall > Advanced > Application Inspection > remove 'sip' from policy-map" }
        'Netgear'            { "Advanced > WAN Setup > uncheck 'Disable SIP ALG'" }
        'ASUS'               { "Advanced Settings > WAN > NAT Passthrough > SIP Passthrough: Disable" }
        'TP-Link'            { "Advanced > NAT Forwarding > ALG > uncheck SIP" }
        'Linksys'            { "Security > Apps and Gaming > SIP ALG: Disable" }
        'Fortinet FortiGate' { "VoIP > SIP > disable SIP session helper; CLI: config system session-helper / delete entry for SIP" }
        'SonicWall'          { "VoIP > Settings > uncheck 'Enable SIP Transformations'" }
        'MikroTik'           { "IP > Firewall > Service Ports > disable 'sip'" }
        'pfSense'            { "System > Advanced > Firewall & NAT > uncheck 'Enable SIP Proxy'" }
        'OPNsense'           { "Firewall > Settings > Advanced > uncheck 'Disable SIP proxy'" }
        'WatchGuard'         { "Firewall Policies > Application Control > remove SIP ALG" }
        default              { "Log into your router admin at $routerAdminUrl and search for 'SIP ALG', 'SIP Helper', or 'VoIP ALG'  -  disable it" }
    }

    Append-ResultBox $rtbResults '[!]' "SIP ALG  -  ACTION REQUIRED on router" $sipAlgSteps 'WARN'
    Add-ResultRow '[!]' "SIP ALG" $sipAlgSteps 'WARN'

    # --- 3d. Router outbound port guidance (for SIP phones on LAN) ---
    $script:reportLines.Add("")
    $script:reportLines.Add("ROUTER PORTS REQUIRED (apply in router admin at $routerAdminUrl)")
    $script:reportLines.Add("  Outbound  TCP/UDP 5060   -> FieldPulse SIP IPs (SIP signaling)")
    $script:reportLines.Add("  Outbound  TCP     5061   -> FieldPulse SIP IPs (SIP TLS)")
    $script:reportLines.Add("  Outbound  UDP 10000-20000 -> 168.86.128.0/18   (RTP media)")
    $script:reportLines.Add("  These rules apply to ALL devices on the LAN (SIP phones, PCs).")

    Append-ResultBox $rtbResults '[i]' "Router port config required" "Open outbound TCP/UDP 5060, TCP 5061, UDP 10000-20000 in router admin for all LAN devices" 'INFO'

    # --- 3e. UPnP availability check ---
    $upnpAvailable = $false
    try {
        $nat = New-Object -ComObject HNetCfg.NATUPnP -ErrorAction Stop
        if ($null -ne $nat.StaticPortMappingCollection) { $upnpAvailable = $true }
    } catch { }

    if ($upnpAvailable) {
        Append-ResultBox $rtbResults '[i]' "UPnP detected on router" "Router supports UPnP  -  SIP phones may negotiate ports automatically if enabled on the phone" 'INFO'
        Add-ResultRow '[i]' "UPnP" "Available on router" 'INFO'
    } else {
        Append-ResultBox $rtbResults '[i]' "UPnP not detected" "Router port rules must be added manually in router admin" 'INFO'
        Add-ResultRow '[i]' "UPnP" "Not available  -  manual router config required" 'INFO'
    }

    # --- 3f. Windows Firewall (PC-only  -  does NOT affect SIP phones) ---
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    Append-ResultBox $rtbResults '[i]' "Windows Firewall (this PC only)" "The check below applies only to this computer, not SIP phone hardware." 'INFO'

    if (-not $isAdmin) {
        Append-ResultBox $rtbResults '[!]' "Not running as Administrator" "Re-run as Administrator for full Windows Firewall check" 'WARN'
        Add-ResultRow '[!]' "Windows Firewall (PC)" "Limited  -  not Administrator" 'WARN'
    } else {
        $allIPs     = $HTTP_IPS + $SIP_IPS + @('168.86.128.0/18')
        $blockRules = Get-NetFirewallRule -Direction Outbound -Action Block -Enabled True 2>$null
        $conflicts  = @()
        foreach ($rule in $blockRules) {
            $filter = $rule | Get-NetFirewallAddressFilter 2>$null
            foreach ($ip in $allIPs) {
                $baseIP = $ip -replace '/\d+$', ''
                if ($filter.RemoteAddress -contains $ip -or $filter.RemoteAddress -contains $baseIP) {
                    $conflicts += $rule.DisplayName
                }
            }
        }
        if ($conflicts.Count -eq 0) {
            Append-ResultBox $rtbResults '[OK]' "No blocking Windows Firewall rules (PC)" "No outbound block rules targeting FieldPulse IPs on this computer" 'PASS'
            Add-ResultRow '[OK]' "Windows Firewall (PC)" "No conflicting outbound block rules" 'PASS'
        } else {
            foreach ($c in $conflicts) {
                Append-ResultBox $rtbResults '[X]' "Windows Firewall blocking rule (PC)" $c 'FAIL'
                Add-ResultRow '[X]' "Windows Firewall (PC) block rule" $c 'FAIL'
            }
        }
    }

    # -- CHECK 4  -  Device discovery ----------------------------
    Set-Status $lblStatus $progressBar 'Scanning network devices...' 85
    Write-Section "4. DEVICES ON YOUR NETWORK  (for FieldPulse team)"

    try {
        $dns = Resolve-DnsName 'sip.twilio.com' -ErrorAction Stop | Select-Object -First 1
        Append-ResultBox $rtbResults '[OK]' "DNS working" "sip.twilio.com -> $($dns.IPAddress)" 'PASS'
        Add-ResultRow '[OK]' "DNS" "Resolved sip.twilio.com -> $($dns.IPAddress)" 'PASS'
    } catch {
        Append-ResultBox $rtbResults '[X]' "DNS FAILED" "Could not resolve sip.twilio.com  -  check DNS settings" 'FAIL'
        Add-ResultRow '[X]' "DNS" "Could not resolve sip.twilio.com" 'FAIL'
    }

    # Known SIP phone OUI prefixes (first 3 MAC octets, uppercase, colon-separated)
    $sipOUIs = @{
        '80:5E:C0' = 'Yealink';  '00:15:65' = 'Yealink';  'DC:2C:6E' = 'Yealink'
        '64:16:7F' = 'Polycom';  '00:04:F2' = 'Polycom'
        '00:0B:82' = 'Grandstream'; 'C0:74:AD' = 'Grandstream'
        '00:1B:54' = 'Cisco IP Phone'; 'D8:96:95' = 'Cisco IP Phone'
        'F8:B1:56' = 'Cisco IP Phone'; '00:14:6A' = 'Cisco IP Phone'
        '00:04:13' = 'Snom';     '00:1A:E8' = 'Snom'
        '00:A8:59' = 'Fanvil';   '9C:28:EF' = 'Fanvil'
        '00:30:48' = 'Obihai'
        '00:04:0D' = 'Avaya';    '00:1B:4F' = 'Avaya'
        '08:00:0F' = 'Mitel';    '00:90:7A' = 'Mitel'
    }

    $arpLines = (arp -a 2>$null) | Where-Object {
        $_ -match '^\s+\d{1,3}\.' -and $_ -notmatch '224\.' -and $_ -notmatch '239\.' -and $_ -notmatch '255\.'
    }
    $deviceCount  = 0
    $sipDevices   = [System.Collections.Generic.List[string]]::new()

    $script:reportLines.Add("`nDEVICE DISCOVERY (ARP TABLE)")
    $script:reportLines.Add("IP Address          MAC Address         Vendor")
    $script:reportLines.Add("-" * 60)

    foreach ($line in $arpLines) {
        if ($line -match '(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\s+([\w-]{11,17})\s+dynamic') {
            $devIP  = $Matches[1]
            # Normalize MAC to XX:XX:XX:XX:XX:XX uppercase colon format
            $devMAC = $Matches[2].ToUpper() -replace '-', ':'
            $oui    = ($devMAC -split ':')[0..2] -join ':'
            $vendor = if ($sipOUIs.ContainsKey($oui)) { $sipOUIs[$oui] } else { '' }
            $script:reportLines.Add("$($devIP.PadRight(20))$($devMAC.PadRight(20))$vendor")
            if ($vendor) { $sipDevices.Add("$devIP  $devMAC  ($vendor)") }
            $deviceCount++
        }
    }

    if ($sipDevices.Count -gt 0) {
        $sipList = $sipDevices -join '; '
        Append-ResultBox $rtbResults '[OK]' "SIP phones detected on network" "$($sipDevices.Count) device(s): $sipList" 'PASS'
        Add-ResultRow '[OK]' "SIP phones detected" "$($sipDevices.Count) device(s) found by MAC OUI" 'PASS'
        $script:reportLines.Add("`nDETECTED SIP PHONES")
        foreach ($d in $sipDevices) { $script:reportLines.Add("  $d") }
    } else {
        Append-ResultBox $rtbResults '[i]' "No known SIP phones detected" "Phones may be offline, not yet on network, or use an unlisted OUI" 'INFO'
        Add-ResultRow '[i]' "SIP phones" "None detected by MAC OUI  -  may be offline or not yet connected" 'INFO'
    }
    Append-ResultBox $rtbResults '[i]' "Total devices on network" "$deviceCount devices  -  full ARP table in saved report" 'INFO'
    Add-ResultRow '[i]' "Network devices" "$deviceCount total devices in ARP table" 'INFO'

    # -- SUMMARY -----------------------------------------------
    Set-Status $lblStatus $progressBar 'Finalizing...' 98
    Write-Section "SUMMARY"

    $pass = ($script:results | Where-Object { $_.Status -eq 'PASS' }).Count
    $fail = ($script:results | Where-Object { $_.Status -eq 'FAIL' }).Count
    $warn = ($script:results | Where-Object { $_.Status -eq 'WARN' }).Count

    $summaryColor = if ($fail -gt 0) { $clrRed } elseif ($warn -gt 2) { $clrOrange } else { $clrGreen }
    $summaryText  = if ($fail -gt 0) {
        "Action required  -  fix FAIL items before SIP phones can register."
    } elseif ($warn -gt 2) {
        "Some warnings need attention before onboarding. Review items above."
    } else {
        "Your environment looks ready! Notify the FieldPulse team."
    }

    $rtbResults.SelectionColor = $summaryColor
    $rtbResults.SelectionFont  = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $rtbResults.AppendText("`n  $summaryText`n")
    $rtbResults.SelectionColor = $clrGray
    $rtbResults.SelectionFont  = $fontMeta
    $rtbResults.AppendText("  Results: $pass PASS  -  $warn WARN  -  $fail FAIL`n")

    $rtbResults.SelectionColor = $clrOrange
    $rtbResults.SelectionFont  = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $rtbResults.AppendText("`n  Still required manually:`n")
    $rtbResults.SelectionColor = $clrGray
    $rtbResults.SelectionFont  = $fontMeta
    $rtbResults.AppendText("  - Disable SIP ALG in your router`n")
    $rtbResults.AppendText("  - Contact former phone system provider to release devices`n")
    $rtbResults.AppendText("  - Factory reset SIP phones`n")
    $rtbResults.AppendText("  - Update SIP phone firmware`n")
    $rtbResults.ScrollToCaret()

    $script:reportLines.Add("$pass PASS  |  $warn WARN  |  $fail FAIL")
    $script:reportLines.Add($summaryText)

    Set-Status $lblStatus $progressBar 'Done! Click Send to FieldPulse or Save Report.' 100

    $script:checksRan   = $true
    $btnRun.Enabled     = $true
    $btnSend.Enabled    = $true
    $btnSave.Enabled    = $true
})

# -------------------------------------------------------------
# BUILD REPORT TEXT (shared helper)
# -------------------------------------------------------------
function Get-ReportText {
    param([hashtable]$Onboarding = $null)
    $customerName = if ($txtName.Text.Trim()) { $txtName.Text.Trim() } else { 'Unknown Customer' }
    $header = @"
$("=" * 60)
  FIELDPULSE ENGAGE  -  SIP READINESS REPORT
$("=" * 60)
  Customer  : $customerName
  Computer  : $env:COMPUTERNAME
  User      : $env:USERNAME
  Date      : $(Get-Date -Format 'yyyy-MM-dd HH:mm')
  Local IP  : $($script:localIP)
  Gateway   : $($script:gateway)
  Public IP : $($script:publicIP)
$("=" * 60)

"@
    $body = $header + ($script:reportLines -join "`n")

    if ($Onboarding) {
        $c1 = if ($Onboarding.ConfirmedFormerProvider) { 'YES' } else { 'NO' }
        $c2 = if ($Onboarding.ConfirmedFactoryReset)   { 'YES' } else { 'NO' }
        $c3 = if ($Onboarding.ConfirmedFirmware)       { 'YES' } else { 'NO' }
        $body += @"

$("=" * 60)
  ONBOARDING INFORMATION
$("-" * 60)
  Phone count    : $($Onboarding.PhoneCountText)
  Phone brand    : $($Onboarding.PhoneBrand)
  Phone model(s) : $($Onboarding.PhoneModels)
  Config type    : $($Onboarding.ConfigType)
  MAC / Serials  : $($Onboarding.MacSerials)
  Config notes   : $($Onboarding.ConfigNotes)
  Preferred time : $($Onboarding.PreferredTime)
  Attendee(s)    : $($Onboarding.Attendees)
$("-" * 60)
  CUSTOMER CONFIRMATIONS
  Former provider contacted : $c1
  SIP phones factory reset  : $c2
  Firmware updated          : $c3
$("=" * 60)
"@
        # Phone inventory table — appended when CSV was uploaded
        if ($Onboarding.PhoneCSV -and $Onboarding.PhoneCSV.Count -gt 0) {
            $body += "`n$("=" * 78)`n"
            $body += "  PHONE INVENTORY  ($($Onboarding.PhoneCSV.Count) phone(s) from uploaded CSV)`n"
            $body += "  $("-" * 76)`n"
            $body += "  #    Model                MAC Address         Serial          Ext    Label`n"
            $body += "  $("-" * 76)`n"
            $n = 1
            foreach ($ph in $Onboarding.PhoneCSV) {
                $body += "  $($n.ToString().PadRight(5))"
                $body += "$($ph.PhoneModel.PadRight(21))"
                $body += "$($ph.MACAddress.PadRight(20))"
                $body += "$($ph.SerialNumber.PadRight(16))"
                $body += "$($ph.Extension.PadRight(7))"
                $body += "$($ph.LineLabel)`n"
                $n++
            }
            $body += "  $("=" * 78)`n"
        }
    } else {
        $body += @"

$("=" * 60)
  MANUAL ACTION STILL REQUIRED
  - Disable SIP ALG in router (SIP Helper / VoIP ALG)
  - Contact former phone system provider to release devices
  - Factory reset SIP phones before FieldPulse configuration
  - Update SIP phone firmware to latest stable version
$("=" * 60)
"@
    }
    return $body
}

# -------------------------------------------------------------
# PHONE CSV VALIDATION
# -------------------------------------------------------------
function Invoke-PhoneCSVValidation {
    param([string]$FilePath)
    $out = @{
        Valid  = $false
        Phones = [System.Collections.Generic.List[hashtable]]::new()
        Errors = [System.Collections.Generic.List[string]]::new()
    }
    try {
        # File size limit: 200 KB
        $info = Get-Item $FilePath -ErrorAction Stop
        if ($info.Length -gt 204800) {
            $out.Errors.Add("File is too large (limit: 200 KB)."); return $out
        }

        $raw = [System.IO.File]::ReadAllText($FilePath, [System.Text.Encoding]::UTF8)

        # Null byte / binary check
        if ($raw.IndexOf([char]0) -ge 0) {
            $out.Errors.Add("File contains null bytes  -  may be binary or corrupt."); return $out
        }

        $lines = ($raw -split '\r?\n') | Where-Object { $_.Trim() -ne '' }

        if ($lines.Count -lt 2) {
            $out.Errors.Add("CSV must have a header row and at least one data row."); return $out
        }

        # Parse and validate header row
        $headers = $lines[0] -split ',' | ForEach-Object { $_.Trim().Trim('"') }
        foreach ($req in @('PhoneModel','MACAddress','SerialNumber')) {
            if ($headers -notcontains $req) {
                $out.Errors.Add("Missing required column: $req.  Use the Download Template button for the correct format.")
                return $out
            }
        }

        # Build column index map
        $idx = @{}
        for ($i = 0; $i -lt $headers.Count; $i++) { $idx[$headers[$i]] = $i }

        $rowNum = 1
        foreach ($line in $lines[1..($lines.Count - 1)]) {
            $rowNum++

            # Split fields (basic CSV  -  fields containing commas must be quoted)
            $fields = $line -split ',' | ForEach-Object { $_.Trim().Trim('"') }

            $model  = if ($idx.ContainsKey('PhoneModel')   -and $idx['PhoneModel']   -lt $fields.Count) { $fields[$idx['PhoneModel']]   } else { '' }
            $mac    = if ($idx.ContainsKey('MACAddress')   -and $idx['MACAddress']   -lt $fields.Count) { $fields[$idx['MACAddress']]   } else { '' }
            $serial = if ($idx.ContainsKey('SerialNumber') -and $idx['SerialNumber'] -lt $fields.Count) { $fields[$idx['SerialNumber']] } else { '' }
            $ext    = if ($idx.ContainsKey('Extension')    -and $idx['Extension']    -lt $fields.Count) { $fields[$idx['Extension']]    } else { '' }
            $lbl    = if ($idx.ContainsKey('LineLabel')    -and $idx['LineLabel']    -lt $fields.Count) { $fields[$idx['LineLabel']]    } else { '' }

            # Security checks on every field value
            foreach ($val in @($model,$mac,$serial,$ext,$lbl)) {

                # 1. Formula / CSV injection  (Excel, Sheets, LibreOffice)
                #    Covers standard prefix chars and the DDE cmd| variant
                if ($val -match '^[=+\-@|]') {
                    $out.Errors.Add("Row $rowNum: Formula injection detected  -  value starts with '$($val[0])'. Remove leading =, +, -, @, or | characters.")
                }
                if ($val -match '(?i)^cmd\s*\|') {
                    $out.Errors.Add("Row $rowNum: DDE command injection detected (cmd|). Value rejected.")
                }

                # 2. HTML / script injection  (data reaches an HTML email via GAS)
                if ($val -match '<\s*(script|iframe|img|svg|object|embed|link|meta|form|input|button|a)\b') {
                    $out.Errors.Add("Row $rowNum: HTML tag detected in value. HTML is not permitted in CSV fields.")
                }
                if ($val -match '(?i)(javascript|vbscript)\s*:') {
                    $out.Errors.Add("Row $rowNum: Script URI (javascript: / vbscript:) detected. Value rejected.")
                }

                # 3. Embedded newline / CRLF injection  (can forge extra CSV rows or email headers)
                if ($val -match '[\r\n]') {
                    $out.Errors.Add("Row $rowNum: Embedded newline detected in a field value. Strip line breaks and re-save.")
                }

                # 4. Control characters  (permit tab only)
                if ($val -match '[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]') {
                    $out.Errors.Add("Row $rowNum: Contains invalid control characters.")
                }
            }

            # Field format validation
            if (-not $model) {
                $out.Errors.Add("Row $rowNum: PhoneModel is required.")
            } elseif ($model.Length -gt 100) {
                $out.Errors.Add("Row $rowNum: PhoneModel exceeds 100 characters.")
            }

            if (-not $mac) {
                $out.Errors.Add("Row $rowNum: MACAddress is required.")
            } elseif ($mac -notmatch '^([0-9A-Fa-f]{2}[:\-]){5}[0-9A-Fa-f]{2}$') {
                $out.Errors.Add("Row $rowNum: MACAddress '$mac'  -  expected format AA:BB:CC:DD:EE:FF")
            }

            if ($serial -and $serial.Length -gt 50) {
                $out.Errors.Add("Row $rowNum: SerialNumber exceeds 50 characters.")
            }

            if ($ext -and $ext -notmatch '^\d{1,10}$') {
                $out.Errors.Add("Row $rowNum: Extension '$ext' must be numeric (up to 10 digits).")
            }

            if ($lbl.Length -gt 50) {
                $out.Errors.Add("Row $rowNum: LineLabel exceeds 50 characters.")
            }

            $cleanMAC = if ($mac -match '^([0-9A-Fa-f]{2}[:\-]){5}[0-9A-Fa-f]{2}$') {
                            $mac.ToUpper() -replace '-', ':'
                        } else { $mac }

            $out.Phones.Add(@{
                PhoneModel   = $model
                MACAddress   = $cleanMAC
                SerialNumber = $serial
                Extension    = $ext
                LineLabel    = $lbl
            })
        }

        if ($out.Errors.Count -eq 0) { $out.Valid = $true }

    } catch {
        $out.Errors.Add("Could not read file: $_")
    }
    return $out
}

# -------------------------------------------------------------
# ONBOARDING SUBMISSION DIALOG
# -------------------------------------------------------------
function Show-SubmissionDialog {
    $dlg                 = New-Object System.Windows.Forms.Form
    $dlg.Text            = 'Complete Your Submission'
    $dlg.StartPosition   = 'CenterParent'
    $dlg.BackColor       = $clrBg
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox     = $false
    $dlg.MinimizeBox     = $false

    $y = 14

    # -- Title --
    $lTitle           = New-Object System.Windows.Forms.Label
    $lTitle.Text      = 'Onboarding Information'
    $lTitle.Font      = New-Object System.Drawing.Font('Segoe UI', 10, [System.Drawing.FontStyle]::Bold)
    $lTitle.ForeColor = $clrBlue
    $lTitle.Location  = New-Object System.Drawing.Point(14, $y)
    $lTitle.AutoSize  = $true
    $dlg.Controls.Add($lTitle)
    $y += 26

    $lSub           = New-Object System.Windows.Forms.Label
    $lSub.Text      = 'Complete these details before sending to FieldPulse.'
    $lSub.Font      = $fontMeta
    $lSub.ForeColor = $clrGray
    $lSub.Location  = New-Object System.Drawing.Point(14, $y)
    $lSub.AutoSize  = $true
    $dlg.Controls.Add($lSub)
    $y += 28

    $sep1           = New-Object System.Windows.Forms.Panel
    $sep1.Location  = New-Object System.Drawing.Point(0, $y)
    $sep1.Size      = New-Object System.Drawing.Size(520, 1)
    $sep1.BackColor = $clrBorder
    $dlg.Controls.Add($sep1)
    $y += 12

    # -- Number of SIP phones --
    $lPhones           = New-Object System.Windows.Forms.Label
    $lPhones.Text      = 'Number of SIP phones:'
    $lPhones.Font      = $fontMeta
    $lPhones.ForeColor = $clrGray
    $lPhones.Location  = New-Object System.Drawing.Point(14, ($y + 3))
    $lPhones.Size      = New-Object System.Drawing.Size(148, 20)
    $dlg.Controls.Add($lPhones)
    $txtPhoneCount          = New-Object System.Windows.Forms.TextBox
    $txtPhoneCount.Location = New-Object System.Drawing.Point(164, $y)
    $txtPhoneCount.Size     = New-Object System.Drawing.Size(336, 24)
    $txtPhoneCount.Font     = $fontMeta
    $txtPhoneCount.MaxLength = 120
    $dlg.Controls.Add($txtPhoneCount)
    $y += 32

    # -- Phone model(s) --
    $lModels           = New-Object System.Windows.Forms.Label
    $lModels.Text      = 'Phone model(s):'
    $lModels.Font      = $fontMeta
    $lModels.ForeColor = $clrGray
    $lModels.Location  = New-Object System.Drawing.Point(14, ($y + 3))
    $lModels.Size      = New-Object System.Drawing.Size(148, 20)
    $dlg.Controls.Add($lModels)
    $txtModels          = New-Object System.Windows.Forms.TextBox
    $txtModels.Location = New-Object System.Drawing.Point(164, $y)
    $txtModels.Size     = New-Object System.Drawing.Size(336, 24)
    $txtModels.Font     = $fontMeta
    $txtModels.MaxLength = 200
    $dlg.Controls.Add($txtModels)
    $y += 32

    # -- Phone brand --
    $lBrand           = New-Object System.Windows.Forms.Label
    $lBrand.Text      = 'Phone brand:'
    $lBrand.Font      = $fontMeta
    $lBrand.ForeColor = $clrGray
    $lBrand.Location  = New-Object System.Drawing.Point(14, ($y + 3))
    $lBrand.Size      = New-Object System.Drawing.Size(148, 20)
    $dlg.Controls.Add($lBrand)
    $cboBrand              = New-Object System.Windows.Forms.ComboBox
    $cboBrand.Location     = New-Object System.Drawing.Point(164, $y)
    $cboBrand.Size         = New-Object System.Drawing.Size(200, 24)
    $cboBrand.Font         = $fontMeta
    $cboBrand.DropDownStyle = 'DropDown'
    @('Yealink','Polycom','Cisco','Grandstream','Snom','Fanvil','Avaya','Mitel','Obihai','Other') |
        ForEach-Object { [void]$cboBrand.Items.Add($_) }
    $dlg.Controls.Add($cboBrand)
    $y += 32

    # -- Configuration type --
    $lConfigType           = New-Object System.Windows.Forms.Label
    $lConfigType.Text      = 'Configuration type:'
    $lConfigType.Font      = $fontMeta
    $lConfigType.ForeColor = $clrGray
    $lConfigType.Location  = New-Object System.Drawing.Point(14, ($y + 3))
    $lConfigType.Size      = New-Object System.Drawing.Size(148, 20)
    $dlg.Controls.Add($lConfigType)
    $cboConfigType              = New-Object System.Windows.Forms.ComboBox
    $cboConfigType.Location     = New-Object System.Drawing.Point(164, $y)
    $cboConfigType.Size         = New-Object System.Drawing.Size(200, 24)
    $cboConfigType.Font         = $fontMeta
    $cboConfigType.DropDownStyle = 'DropDown'
    @('PBX','Direct SIP','Hosted PBX','Cloud PBX','UCaaS Platform','Other') |
        ForEach-Object { [void]$cboConfigType.Items.Add($_) }
    $dlg.Controls.Add($cboConfigType)
    $y += 32

    # -- MAC / Serial numbers --
    $lMac           = New-Object System.Windows.Forms.Label
    $lMac.Text      = 'MAC / Serial numbers:'
    $lMac.Font      = $fontMeta
    $lMac.ForeColor = $clrGray
    $lMac.Location  = New-Object System.Drawing.Point(14, ($y + 3))
    $lMac.Size      = New-Object System.Drawing.Size(148, 20)
    $dlg.Controls.Add($lMac)
    $txtMac             = New-Object System.Windows.Forms.TextBox
    $txtMac.Location    = New-Object System.Drawing.Point(164, $y)
    $txtMac.Size        = New-Object System.Drawing.Size(336, 52)
    $txtMac.Font        = $fontMeta
    $txtMac.Multiline   = $true
    $txtMac.ScrollBars  = 'Vertical'
    $txtMac.MaxLength   = 1000
    $dlg.Controls.Add($txtMac)
    $y += 60

    # -- CSV: Download template + Upload CSV row --
    $btnCsvTpl              = New-Object System.Windows.Forms.Button
    $btnCsvTpl.Text         = 'Download Template'
    $btnCsvTpl.Font         = $fontMeta
    $btnCsvTpl.Size         = New-Object System.Drawing.Size(154, 26)
    $btnCsvTpl.Location     = New-Object System.Drawing.Point(164, $y)
    $btnCsvTpl.BackColor    = $clrRowAlt
    $btnCsvTpl.ForeColor    = $clrBlue
    $btnCsvTpl.FlatStyle    = 'Flat'
    $btnCsvTpl.FlatAppearance.BorderColor = $clrBorder
    $btnCsvTpl.Cursor       = 'Hand'
    $dlg.Controls.Add($btnCsvTpl)

    $btnCsvUpload              = New-Object System.Windows.Forms.Button
    $btnCsvUpload.Text         = 'Upload Phone CSV'
    $btnCsvUpload.Font         = $fontMeta
    $btnCsvUpload.Size         = New-Object System.Drawing.Size(154, 26)
    $btnCsvUpload.Location     = New-Object System.Drawing.Point(324, $y)
    $btnCsvUpload.BackColor    = $clrRowAlt
    $btnCsvUpload.ForeColor    = $clrBlue
    $btnCsvUpload.FlatStyle    = 'Flat'
    $btnCsvUpload.FlatAppearance.BorderColor = $clrBorder
    $btnCsvUpload.Cursor       = 'Hand'
    $dlg.Controls.Add($btnCsvUpload)
    $y += 32

    # Status label shown after upload attempt
    $lblCsvStatus           = New-Object System.Windows.Forms.Label
    $lblCsvStatus.Text      = 'Optional  -  for 5+ phones, use a CSV instead of typing above.'
    $lblCsvStatus.Font      = $fontMeta
    $lblCsvStatus.ForeColor = $clrGray
    $lblCsvStatus.Location  = New-Object System.Drawing.Point(164, $y)
    $lblCsvStatus.Size      = New-Object System.Drawing.Size(336, 18)
    $dlg.Controls.Add($lblCsvStatus)
    $y += 26

    # Download button click
    $btnCsvTpl.Add_Click({
        $csvPath = "$env:USERPROFILE\Desktop\FieldPulse-Phone-Template.csv"
        try {
            $csvLines  = "PhoneModel,MACAddress,SerialNumber,Extension,LineLabel`r`n"
            $csvLines += "Yealink T46U,AA:BB:CC:DD:EE:FF,ABC123456,101,Front Desk`r`n"
            $csvLines += "Polycom VVX 411,BB:CC:DD:EE:FF:00,DEF789012,102,Reception`r`n"
            [System.IO.File]::WriteAllText($csvPath, $csvLines, [System.Text.Encoding]::UTF8)
            [System.Windows.Forms.MessageBox]::Show(
                "Template saved to Desktop:`n$csvPath`n`nFill in one row per phone in Excel.`nMAC format: AA:BB:CC:DD:EE:FF  |  Extension: numbers only`n`nThen click 'Upload Phone CSV' to load it here.",
                "Template Downloaded",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            ) | Out-Null
        } catch {
            [System.Windows.Forms.MessageBox]::Show(
                "Could not save template.`n`n$_",
                "Error",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Error
            ) | Out-Null
        }
    })

    # Upload button click  -  validate and import CSV
    $btnCsvUpload.Add_Click({
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Title  = 'Select Phone CSV File'
        $ofd.Filter = 'CSV files (*.csv)|*.csv|All files (*.*)|*.*'
        if ($ofd.ShowDialog($dlg) -ne [System.Windows.Forms.DialogResult]::OK) { return }

        $parsed = Invoke-PhoneCSVValidation -FilePath $ofd.FileName

        if (-not $parsed.Valid) {
            $maxShow = 12
            $errList = $parsed.Errors[0..[Math]::Min($maxShow - 1, $parsed.Errors.Count - 1)] -join "`n"
            if ($parsed.Errors.Count -gt $maxShow) {
                $errList += "`n... and $($parsed.Errors.Count - $maxShow) more error(s)."
            }
            [System.Windows.Forms.MessageBox]::Show(
                "CSV validation failed  -  fix the errors below and re-upload:`n`n$errList",
                "Validation Errors",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
            $lblCsvStatus.Text      = "CSV rejected  -  $($parsed.Errors.Count) error(s) found.  Fix and re-upload."
            $lblCsvStatus.ForeColor = $clrRed
            $script:phoneCSVLoaded  = $null
            return
        }

        # Valid  -  populate form fields from CSV data
        $script:phoneCSVLoaded  = $parsed.Phones
        $txtPhoneCount.Text     = "$($parsed.Phones.Count)"
        $uniqueModels           = ($parsed.Phones | ForEach-Object { $_.PhoneModel } | Select-Object -Unique) -join ', '
        # Auto-set brand if all phones share a single brand (match against known brands)
        $knownBrands = @('Yealink','Polycom','Cisco','Grandstream','Snom','Fanvil','Avaya','Mitel','Obihai')
        $detectedBrand = $knownBrands | Where-Object { $uniqueModels -match $_ } | Select-Object -First 1
        if ($detectedBrand -and -not $cboBrand.Text.Trim()) { $cboBrand.Text = $detectedBrand }
        $txtModels.Text        = $uniqueModels
        $macSummary            = ($parsed.Phones | ForEach-Object {
            "$($_.MACAddress)  SN:$($_.SerialNumber)  Ext:$($_.Extension)  $($_.LineLabel)"
        }) -join "`r`n"
        $txtMac.Text            = $macSummary
        $lblCsvStatus.Text      = "$($parsed.Phones.Count) phone(s) loaded from CSV  -  included in report."
        $lblCsvStatus.ForeColor = $clrGreen
    })

    # -- Desired configuration --
    $lNotes           = New-Object System.Windows.Forms.Label
    $lNotes.Text      = 'Desired configuration:'
    $lNotes.Font      = $fontMeta
    $lNotes.ForeColor = $clrGray
    $lNotes.Location  = New-Object System.Drawing.Point(14, ($y + 3))
    $lNotes.Size      = New-Object System.Drawing.Size(148, 20)
    $dlg.Controls.Add($lNotes)
    $txtNotes           = New-Object System.Windows.Forms.TextBox
    $txtNotes.Location  = New-Object System.Drawing.Point(164, $y)
    $txtNotes.Size      = New-Object System.Drawing.Size(336, 52)
    $txtNotes.Font      = $fontMeta
    $txtNotes.Multiline = $true
    $txtNotes.ScrollBars = 'Vertical'
    $txtNotes.MaxLength = 1000
    $dlg.Controls.Add($txtNotes)
    $y += 60

    # -- Preferred time of day + Timezone --
    $lTime           = New-Object System.Windows.Forms.Label
    $lTime.Text      = 'Preferred time of day:'
    $lTime.Font      = $fontMeta
    $lTime.ForeColor = $clrGray
    $lTime.Location  = New-Object System.Drawing.Point(14, ($y + 3))
    $lTime.Size      = New-Object System.Drawing.Size(148, 20)
    $dlg.Controls.Add($lTime)
    $cboTime              = New-Object System.Windows.Forms.ComboBox
    $cboTime.Location     = New-Object System.Drawing.Point(164, $y)
    $cboTime.Size         = New-Object System.Drawing.Size(176, 24)
    $cboTime.Font         = $fontMeta
    $cboTime.DropDownStyle = 'DropDown'
    @('ASAP','Mon-Fri  9:00am - 12:00pm CT', 'Mon-Fri  1:00pm - 3:00pm CT', 'Mon-Fri  3:00pm - 6:00pm CT') |
        ForEach-Object { [void]$cboTime.Items.Add($_) }
    $cboTime.SelectedIndex = 0
    $dlg.Controls.Add($cboTime)
    $y += 32

    # -- Customer attendee(s) --
    $lAttendees           = New-Object System.Windows.Forms.Label
    $lAttendees.Text      = 'Customer attendee(s):'
    $lAttendees.Font      = $fontMeta
    $lAttendees.ForeColor = $clrGray
    $lAttendees.Location  = New-Object System.Drawing.Point(14, ($y + 3))
    $lAttendees.Size      = New-Object System.Drawing.Size(148, 20)
    $dlg.Controls.Add($lAttendees)

    # Name input
    $txtAttendeeName          = New-Object System.Windows.Forms.TextBox
    $txtAttendeeName.Location = New-Object System.Drawing.Point(164, $y)
    $txtAttendeeName.Size     = New-Object System.Drawing.Size(120, 24)
    $txtAttendeeName.Font     = $fontMeta
    $txtAttendeeName.MaxLength = 80
    $dlg.Controls.Add($txtAttendeeName)

    # Email input
    $txtAttendeeEmail          = New-Object System.Windows.Forms.TextBox
    $txtAttendeeEmail.Location = New-Object System.Drawing.Point(288, $y)
    $txtAttendeeEmail.Size     = New-Object System.Drawing.Size(166, 24)
    $txtAttendeeEmail.Font     = $fontMeta
    $txtAttendeeEmail.MaxLength = 120
    $dlg.Controls.Add($txtAttendeeEmail)

    # Add button
    $btnAddAttendee              = New-Object System.Windows.Forms.Button
    $btnAddAttendee.Text         = '+ Add'
    $btnAddAttendee.Font         = $fontMeta
    $btnAddAttendee.Size         = New-Object System.Drawing.Size(50, 24)
    $btnAddAttendee.Location     = New-Object System.Drawing.Point(458, $y)
    $btnAddAttendee.BackColor    = $clrBlue
    $btnAddAttendee.ForeColor    = [System.Drawing.Color]::White
    $btnAddAttendee.FlatStyle    = 'Flat'
    $btnAddAttendee.FlatAppearance.BorderSize = 0
    $btnAddAttendee.Cursor       = 'Hand'
    $dlg.Controls.Add($btnAddAttendee)
    $y += 30

    # Column headers hint
    $lAttHdr           = New-Object System.Windows.Forms.Label
    $lAttHdr.Text      = 'Name                              Email'
    $lAttHdr.Font      = New-Object System.Drawing.Font('Consolas', 8)
    $lAttHdr.ForeColor = $clrGray
    $lAttHdr.Location  = New-Object System.Drawing.Point(166, $y)
    $lAttHdr.Size      = New-Object System.Drawing.Size(336, 14)
    $dlg.Controls.Add($lAttHdr)
    $y += 14

    # Attendee ListView
    $lvAttendees                   = New-Object System.Windows.Forms.ListView
    $lvAttendees.Location          = New-Object System.Drawing.Point(164, $y)
    $lvAttendees.Size              = New-Object System.Drawing.Size(336, 76)
    $lvAttendees.View              = 'Details'
    $lvAttendees.FullRowSelect     = $true
    $lvAttendees.MultiSelect       = $false
    $lvAttendees.GridLines         = $true
    $lvAttendees.Font              = $fontMeta
    $lvAttendees.BorderStyle       = 'FixedSingle'
    $lvAttendees.HeaderStyle       = 'None'
    [void]$lvAttendees.Columns.Add('Name',  120)
    [void]$lvAttendees.Columns.Add('Email', 212)
    $dlg.Controls.Add($lvAttendees)
    $y += 82

    # Remove button
    $btnRemoveAttendee              = New-Object System.Windows.Forms.Button
    $btnRemoveAttendee.Text         = 'Remove Selected'
    $btnRemoveAttendee.Font         = $fontMeta
    $btnRemoveAttendee.Size         = New-Object System.Drawing.Size(130, 22)
    $btnRemoveAttendee.Location     = New-Object System.Drawing.Point(370, $y)
    $btnRemoveAttendee.BackColor    = $clrRowAlt
    $btnRemoveAttendee.ForeColor    = $clrRed
    $btnRemoveAttendee.FlatStyle    = 'Flat'
    $btnRemoveAttendee.FlatAppearance.BorderColor = $clrBorder
    $btnRemoveAttendee.Cursor       = 'Hand'
    $dlg.Controls.Add($btnRemoveAttendee)
    $y += 30

    # Add button click  -  validate name + email then insert row
    $btnAddAttendee.Add_Click({
        $name  = $txtAttendeeName.Text.Trim()
        $email = $txtAttendeeEmail.Text.Trim()
        $addErrors = @()

        if (-not $name)  { $addErrors += "Name is required." }
        elseif ($name.Length -gt 80) { $addErrors += "Name exceeds 80 characters." }

        if (-not $email) { $addErrors += "Email is required." }
        elseif ($email -notmatch '^[a-zA-Z0-9.!#$%&''*+/=?^_`{|}~-]+@[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*\.[a-zA-Z]{2,}$') {
            $addErrors += "Email '$email' is not a valid address."
        }

        # Duplicate check
        foreach ($item in $lvAttendees.Items) {
            if ($item.SubItems[1].Text -eq $email) {
                $addErrors += "Email '$email' is already in the list."
            }
        }

        if ($addErrors.Count -gt 0) {
            [System.Windows.Forms.MessageBox]::Show(
                ($addErrors -join "`n"), "Invalid Attendee",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
            return
        }

        $item = New-Object System.Windows.Forms.ListViewItem($name)
        [void]$item.SubItems.Add($email)
        [void]$lvAttendees.Items.Add($item)
        $txtAttendeeName.Text  = ''
        $txtAttendeeEmail.Text = ''
        $txtAttendeeName.Focus()
    })

    # Allow Enter key in email field to trigger Add
    $txtAttendeeEmail.Add_KeyDown({
        if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Return) {
            $btnAddAttendee.PerformClick()
            $_.SuppressKeyPress = $true
        }
    })

    # Remove button click
    $btnRemoveAttendee.Add_Click({
        if ($lvAttendees.SelectedItems.Count -gt 0) {
            $lvAttendees.Items.Remove($lvAttendees.SelectedItems[0])
        }
    })

    # Separator
    $sep2           = New-Object System.Windows.Forms.Panel
    $sep2.Location  = New-Object System.Drawing.Point(0, $y)
    $sep2.Size      = New-Object System.Drawing.Size(520, 1)
    $sep2.BackColor = $clrBorder
    $dlg.Controls.Add($sep2)
    $y += 12

    # -- Self-certification checkboxes --
    $lConfirm           = New-Object System.Windows.Forms.Label
    $lConfirm.Text      = 'Please confirm before sending:'
    $lConfirm.Font      = New-Object System.Drawing.Font('Segoe UI', 9, [System.Drawing.FontStyle]::Bold)
    $lConfirm.ForeColor = $clrGray
    $lConfirm.Location  = New-Object System.Drawing.Point(14, $y)
    $lConfirm.AutoSize  = $true
    $dlg.Controls.Add($lConfirm)
    $y += 24

    $chk1          = New-Object System.Windows.Forms.CheckBox
    $chk1.Text     = 'Former phone system provider contacted  -  devices released'
    $chk1.Font     = $fontMeta
    $chk1.Location = New-Object System.Drawing.Point(14, $y)
    $chk1.Size     = New-Object System.Drawing.Size(490, 20)
    $dlg.Controls.Add($chk1)
    $y += 26

    $chk2          = New-Object System.Windows.Forms.CheckBox
    $chk2.Text     = 'All SIP phones factory reset'
    $chk2.Font     = $fontMeta
    $chk2.Location = New-Object System.Drawing.Point(14, $y)
    $chk2.Size     = New-Object System.Drawing.Size(490, 20)
    $dlg.Controls.Add($chk2)
    $y += 26

    $chk3          = New-Object System.Windows.Forms.CheckBox
    $chk3.Text     = 'SIP phone firmware updated to latest stable version'
    $chk3.Font     = $fontMeta
    $chk3.Location = New-Object System.Drawing.Point(14, $y)
    $chk3.Size     = New-Object System.Drawing.Size(490, 20)
    $dlg.Controls.Add($chk3)
    $y += 34

    # Separator
    $sep3           = New-Object System.Windows.Forms.Panel
    $sep3.Location  = New-Object System.Drawing.Point(0, $y)
    $sep3.Size      = New-Object System.Drawing.Size(520, 1)
    $sep3.BackColor = $clrBorder
    $dlg.Controls.Add($sep3)
    $y += 12

    # -- Buttons --
    $btnSubmit              = New-Object System.Windows.Forms.Button
    $btnSubmit.Text         = 'Send to FieldPulse'
    $btnSubmit.Font         = $fontBtn
    $btnSubmit.Size         = New-Object System.Drawing.Size(180, 38)
    $btnSubmit.Location     = New-Object System.Drawing.Point(14, $y)
    $btnSubmit.BackColor    = $clrBlue
    $btnSubmit.ForeColor    = [System.Drawing.Color]::White
    $btnSubmit.FlatStyle    = 'Flat'
    $btnSubmit.FlatAppearance.BorderSize = 0
    $dlg.Controls.Add($btnSubmit)

    $btnCancel              = New-Object System.Windows.Forms.Button
    $btnCancel.Text         = 'Cancel'
    $btnCancel.Font         = $fontBtn
    $btnCancel.Size         = New-Object System.Drawing.Size(90, 38)
    $btnCancel.Location     = New-Object System.Drawing.Point(202, $y)
    $btnCancel.BackColor    = $clrRowAlt
    $btnCancel.ForeColor    = $clrGray
    $btnCancel.FlatStyle    = 'Flat'
    $btnCancel.FlatAppearance.BorderColor = $clrBorder
    $dlg.Controls.Add($btnCancel)
    $y += 50

    $dlg.ClientSize = New-Object System.Drawing.Size(516, $y)

    $script:dlgData        = $null
    $script:phoneCSVLoaded = $null

    $btnSubmit.Add_Click({
        # -- Field validation --
        $valErrors = [System.Collections.Generic.List[string]]::new()

        # # of phones: must be non-empty and contain at least one digit
        if (-not $txtPhoneCount.Text.Trim()) {
            $valErrors.Add("Number of SIP phones is required.")
        } elseif ($txtPhoneCount.Text -notmatch '\d') {
            $valErrors.Add("Number of SIP phones must contain at least one number.")
        }

        # Phone model: required
        if (-not $txtModels.Text.Trim()) {
            $valErrors.Add("Phone model(s) is required.")
        }

        # Brand: required
        if (-not $cboBrand.Text.Trim()) {
            $valErrors.Add("Phone brand is required.")
        } elseif ($cboBrand.Text.Length -gt 100) {
            $valErrors.Add("Phone brand exceeds 100 characters.")
        }

        # Config type: required
        if (-not $cboConfigType.Text.Trim()) {
            $valErrors.Add("Configuration type is required.")
        } elseif ($cboConfigType.Text.Length -gt 100) {
            $valErrors.Add("Configuration type exceeds 100 characters.")
        }

        # Attendees: at least one row in the ListView
        if ($lvAttendees.Items.Count -eq 0) {
            $valErrors.Add("At least one customer attendee is required.")
        }

        # Preferred time: required
        $timeVal = $cboTime.Text.Trim()
        if (-not $timeVal) {
            $valErrors.Add("Preferred meeting time is required.")
        }

        # Confirmations
        if (-not ($chk1.Checked -and $chk2.Checked -and $chk3.Checked)) {
            $valErrors.Add("All three confirmation checkboxes must be checked.")
        }

        # Security: Check for embedded newlines in text fields (CRLF injection prevention)
        $fieldsToCheck = @(
            @{ Name = 'Phone count';    Value = $txtPhoneCount.Text },
            @{ Name = 'Phone models';   Value = $txtModels.Text },
            @{ Name = 'Phone brand';    Value = $cboBrand.Text },
            @{ Name = 'Config type';    Value = $cboConfigType.Text },
            @{ Name = 'Config notes';   Value = $txtNotes.Text },
            @{ Name = 'Preferred time'; Value = $cboTime.Text }
        )
        foreach ($field in $fieldsToCheck) {
            if ($field.Value -match '[\r\n]' -and $field.Name -ne 'MAC / Serials') {
                $valErrors.Add("$($field.Name) contains invalid line breaks. Please remove them.")
            }
        }

        if ($valErrors.Count -gt 0) {
            [System.Windows.Forms.MessageBox]::Show(
                "Please fix the following before sending:`n`n" + ($valErrors -join "`n"),
                "Required Fields",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
            return
        }

        # Parse first number from phone count text for the integer field
        $phoneCountInt = 0
        if ($txtPhoneCount.Text -match '(\d+)') { $phoneCountInt = [int]$Matches[1] }

        $script:dlgData = @{
            PhoneCount              = $phoneCountInt
            PhoneCountText          = $txtPhoneCount.Text.Trim()
            PhoneModels             = $txtModels.Text.Trim()
            PhoneBrand              = $cboBrand.Text.Trim()
            ConfigType              = $cboConfigType.Text.Trim()
            MacSerials              = $txtMac.Text.Trim()
            ConfigNotes             = $txtNotes.Text.Trim()
            PreferredTime           = $timeVal
            Attendees               = ($lvAttendees.Items | ForEach-Object {
                                        "$($_.Text)  $($_.SubItems[1].Text)"
                                    }) -join '; '
            Timezone                = ''
            ConfirmedFormerProvider = $chk1.Checked
            ConfirmedFactoryReset   = $chk2.Checked
            ConfirmedFirmware       = $chk3.Checked
            PhoneCSV                = $script:phoneCSVLoaded
        }
        $dlg.DialogResult = [System.Windows.Forms.DialogResult]::OK
        $dlg.Close()
    })

    $btnCancel.Add_Click({
        $dlg.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
        $dlg.Close()
    })

    $dlg.ShowDialog($form) | Out-Null
    return $script:dlgData
}

# -------------------------------------------------------------
# SAVE REPORT
# -------------------------------------------------------------
$btnSave.Add_Click({
    if (-not $script:checksRan) { return }
    $reportText = Get-ReportText
    $savePath   = "$env:USERPROFILE\Desktop\FieldPulse-SIP-Readiness-$(Get-Date -Format 'yyyyMMdd-HHmm').txt"
    try {
        $reportText | Out-File -FilePath $savePath -Encoding UTF8
        [System.Windows.Forms.MessageBox]::Show(
            "Report saved to:`n$savePath`n`nShare this file with the FieldPulse team.",
            "Report Saved",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information
        ) | Out-Null
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Could not save to Desktop.`n`n$_",
            "Save Error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
    }
})

# -------------------------------------------------------------
# SEND TO FIELDPULSE  (HTTPS webhook  ->  Google Apps Script)
# -------------------------------------------------------------
$btnSend.Add_Click({
    if (-not $script:checksRan) { return }

    # Guard — secret placeholder not replaced before signing
    if ($WEBHOOK_SECRET -eq 'REPLACE_WITH_YOUR_SECRET' -or $WEBHOOK_SECRET.Length -lt 32) {
        [System.Windows.Forms.MessageBox]::Show(
            "This build was not signed with a valid webhook secret.`n`nPlease use Save Report and email the file to your FieldPulse contact.",
            "Not Configured",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
        return
    }

    # Show onboarding dialog — collect phone info + confirmations
    $onboarding = Show-SubmissionDialog
    if ($null -eq $onboarding) { return }   # user cancelled

    # Sanitize customer name
    $rawName      = $txtName.Text.Trim()
    $customerName = if ($rawName) { $rawName -replace '[^\x20-\x7E]', '' } else { 'Unknown Customer' }

    # Build counts
    $passCount   = ($script:results | Where-Object { $_.Status -eq 'PASS' }).Count
    $failCount   = ($script:results | Where-Object { $_.Status -eq 'FAIL' }).Count
    $warnCount   = ($script:results | Where-Object { $_.Status -eq 'WARN' }).Count
    $reportText  = Get-ReportText -Onboarding $onboarding
    $reportDate  = Get-Date -Format 'yyyy-MM-dd HH:mm'

    # Build JSON payload (network results + onboarding info)
    $payload = [ordered]@{
        customer                  = $customerName
        computer                  = $env:COMPUTERNAME
        date                      = $reportDate
        local_ip                  = $script:localIP
        public_ip                 = $script:publicIP
        gateway                   = $script:gateway
        pass_count                = $passCount
        fail_count                = $failCount
        warn_count                = $warnCount
        phone_count               = $onboarding.PhoneCount
        phone_count_text          = $onboarding.PhoneCountText
        phone_brand               = $onboarding.PhoneBrand
        phone_models              = $onboarding.PhoneModels
        config_type               = $onboarding.ConfigType
        mac_serials               = $onboarding.MacSerials
        config_notes              = $onboarding.ConfigNotes
        preferred_time            = $onboarding.PreferredTime
        attendees                 = $onboarding.Attendees
        confirmed_former_provider = $onboarding.ConfirmedFormerProvider
        confirmed_factory_reset   = $onboarding.ConfirmedFactoryReset
        confirmed_firmware        = $onboarding.ConfirmedFirmware
        phone_csv                 = if ($onboarding.PhoneCSV -and $onboarding.PhoneCSV.Count -gt 0) {
                                        $onboarding.PhoneCSV | ConvertTo-Json -Compress
                                    } else { '' }
        report                    = $reportText
    }
    $jsonBody = $payload | ConvertTo-Json -Compress -Depth 3

    # Compute HMAC-SHA256 signature
    try {
        $keyBytes = [System.Text.Encoding]::UTF8.GetBytes($WEBHOOK_SECRET)
        $msgBytes = [System.Text.Encoding]::UTF8.GetBytes($jsonBody)
        $hmac     = New-Object System.Security.Cryptography.HMACSHA256
        $hmac.Key = $keyBytes
        $sig      = [Convert]::ToBase64String($hmac.ComputeHash($msgBytes))
        $hmac.Dispose()
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Could not compute request signature.`n`nPlease use Save Report instead.`n`nError: $_",
            "Signature Error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
        return
    }

    $btnSend.Enabled = $false
    $btnSend.Text    = '  Sending...'
    Set-Status $lblStatus $progressBar 'Sending report to FieldPulse...' 100
    [System.Windows.Forms.Application]::DoEvents()

    try {
        $uri      = "$WEBHOOK_URL`?sig=$([Uri]::EscapeDataString($sig))"
        $response = Invoke-RestMethod `
            -Uri         $uri `
            -Method      POST `
            -Body        $jsonBody `
            -ContentType 'application/json' `
            -TimeoutSec  $HTTP_REQUEST_TIMEOUT_S `
            -ErrorAction Stop

        if ($response.status -eq 'ok') {
            $btnSend.Text      = 'Sent!'
            $btnSend.BackColor = $clrGreen
            Set-Status $lblStatus $progressBar 'Report sent to FieldPulse team successfully.' 100

            [System.Windows.Forms.MessageBox]::Show(
                "Your readiness report has been sent to the FieldPulse team.`n`nThey will review your results and contact you to schedule configuration.",
                "Report Sent!",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            ) | Out-Null
        } elseif ($response.status -eq 'partial') {
            $btnSend.Text      = 'Saved'
            $btnSend.BackColor = $clrOrange
            Set-Status $lblStatus $progressBar 'Report saved to Drive (email notification pending).' 100

            [System.Windows.Forms.MessageBox]::Show(
                "Your report was saved to FieldPulse's system, but the email notification failed to send.`n`nThe FieldPulse team will retrieve your report from their Drive folder and contact you shortly.",
                "Report Saved",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning
            ) | Out-Null
        } elseif ($response.status -eq 'duplicate') {
            $btnSend.Text      = 'Already Sent'
            $btnSend.BackColor = $clrGray
            Set-Status $lblStatus $progressBar 'Report was already submitted.' 100

            [System.Windows.Forms.MessageBox]::Show(
                "This report was already submitted recently.`n`nIf you need to send an updated report, please wait a few minutes and try again, or use Save Report to create a new file.",
                "Already Submitted",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Information
            ) | Out-Null
        } else {
            $msg = if ($response.message) { $response.message } else { 'Unexpected response from server.' }
            throw $msg
        }

    } catch {
        $btnSend.Text    = 'Send to FieldPulse'
        $btnSend.Enabled = $true
        Set-Status $lblStatus $progressBar 'Send failed  -  please use Save Report and email manually.' 100

        [System.Windows.Forms.MessageBox]::Show(
            "Could not send the report automatically.`n`nPlease use Save Report and email the file to your FieldPulse contact.`n`nError: $_",
            "Send Failed",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
    }
})

# -------------------------------------------------------------
# CLOSE
# -------------------------------------------------------------
$btnClose.Add_Click({ $form.Close() })

# -------------------------------------------------------------
# LAUNCH
# -------------------------------------------------------------
$form.Add_Shown({ $form.Activate() })
[System.Windows.Forms.Application]::Run($form)
