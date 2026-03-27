#Requires -Version 5.1
<#
.SYNOPSIS
    Builds FieldPulse-SIP-Readiness.exe and signs it with a code signing certificate.

.DESCRIPTION
    Two modes:
      -SelfSigned   Creates a self-signed certificate (free, no CA cost).
                    Customers will see a "publisher unknown" SmartScreen prompt once.

      -Thumbprint   Uses an existing commercial certificate already in your cert store
                    (DigiCert, Sectigo, GlobalSign). No prompt shown to customers.

    Both modes:
      1. Install PS2EXE if not already installed
      2. Build FieldPulse-SIP-Readiness.exe from the .ps1
      3. Sign the .exe with the chosen certificate

.NOTES
    Run on Windows as Administrator.

.EXAMPLE
    # Self-signed (free, quick):
    .\Sign-Script.ps1 -SelfSigned

.EXAMPLE
    # Commercial cert already installed:
    .\Sign-Script.ps1 -Thumbprint "AB12CD34EF56..."

.EXAMPLE
    # List available code-signing certs:
    Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert | Select Subject, Thumbprint, NotAfter
#>

[CmdletBinding(DefaultParameterSetName = 'SelfSigned')]
param(
    [Parameter(ParameterSetName = 'SelfSigned', Mandatory = $false)]
    [switch]$SelfSigned,

    [Parameter(ParameterSetName = 'Commercial', Mandatory = $true)]
    [string]$Thumbprint
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptPath = Join-Path $PSScriptRoot 'FieldPulse-SIP-Readiness.ps1'
$ExePath    = Join-Path $PSScriptRoot 'FieldPulse-SIP-Readiness.exe'

if (-not (Test-Path $ScriptPath)) {
    Write-Error "FieldPulse-SIP-Readiness.ps1 not found in $PSScriptRoot"
    exit 1
}

# ── STEP 1: Install PS2EXE if needed ─────────────────────────────────────────
Write-Host "`n[Step 1/3] Checking PS2EXE..." -ForegroundColor Cyan
if (-not (Get-Module -ListAvailable -Name ps2exe)) {
    Write-Host "  Installing PS2EXE module..." -ForegroundColor Yellow
    Install-Module ps2exe -Scope CurrentUser -Force -ErrorAction Stop
    Write-Host "  PS2EXE installed." -ForegroundColor Green
} else {
    Write-Host "  PS2EXE already installed." -ForegroundColor Green
}

# ── STEP 2: Build the .exe ───────────────────────────────────────────────────
Write-Host "`n[Step 2/3] Building EXE from $ScriptPath ..." -ForegroundColor Cyan

Invoke-PS2EXE `
    -InputFile   $ScriptPath `
    -OutputFile  $ExePath `
    -noConsole `
    -requireAdmin `
    -title       'FieldPulse SIP Readiness Check' `
    -description 'SIP Phone Registration Readiness Check' `
    -company     'FieldPulse' `
    -version     '1.0.0.0'

if (-not (Test-Path $ExePath)) {
    Write-Error "EXE build failed — $ExePath not found."
    exit 1
}
Write-Host "  Built: $ExePath" -ForegroundColor Green

# ── STEP 3: Get signing certificate ──────────────────────────────────────────
Write-Host "`n[Step 3/3] Preparing code signing certificate..." -ForegroundColor Cyan

if ($PSCmdlet.ParameterSetName -eq 'SelfSigned') {
    $cert = New-SelfSignedCertificate `
        -Subject           'CN=FieldPulse SIP Readiness, O=FieldPulse' `
        -Type              CodeSigningCert `
        -KeyUsage          DigitalSignature `
        -KeyAlgorithm      RSA `
        -KeyLength         2048 `
        -HashAlgorithm     SHA256 `
        -NotAfter          (Get-Date).AddYears(3) `
        -CertStoreLocation 'Cert:\CurrentUser\My'

    Write-Host "  Created: $($cert.Subject)  [$($cert.Thumbprint)]" -ForegroundColor Green

    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrator')
    if ($isAdmin) {
        $store = New-Object System.Security.Cryptography.X509Certificates.X509Store(
            [System.Security.Cryptography.X509Certificates.StoreName]::TrustedPublisher,
            [System.Security.Cryptography.X509Certificates.StoreLocation]::LocalMachine)
        $store.Open('ReadWrite')
        $store.Add($cert)
        $store.Close()
        Write-Host "  Installed to LocalMachine\TrustedPublisher (no prompt on this machine)." -ForegroundColor Green
    } else {
        Write-Warning "Not Administrator — cert not installed to TrustedPublisher. Run as Administrator to suppress the prompt on this machine."
    }

    Write-Host "`n  NOTE: Customers will see a SmartScreen 'publisher unknown' prompt once." -ForegroundColor Yellow
    Write-Host "  For zero-prompt distribution, purchase a commercial cert from:" -ForegroundColor Yellow
    Write-Host "    Sectigo   — cheapest, ~`$100/yr" -ForegroundColor Yellow
    Write-Host "    DigiCert  — most recognized, ~`$200/yr" -ForegroundColor Yellow
    Write-Host "    GlobalSign — good middle ground" -ForegroundColor Yellow

    $signingCert = $cert
}

if ($PSCmdlet.ParameterSetName -eq 'Commercial') {
    $signingCert = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert |
                   Where-Object { $_.Thumbprint -eq $Thumbprint } |
                   Select-Object -First 1

    if (-not $signingCert) {
        $signingCert = Get-ChildItem Cert:\LocalMachine\My -CodeSigningCert |
                       Where-Object { $_.Thumbprint -eq $Thumbprint } |
                       Select-Object -First 1
    }

    if (-not $signingCert) {
        Write-Error "Certificate '$Thumbprint' not found in CurrentUser\My or LocalMachine\My."
        exit 1
    }

    Write-Host "  Found: $($signingCert.Subject)  expires $($signingCert.NotAfter)" -ForegroundColor Green
}

# ── SIGN THE EXE ─────────────────────────────────────────────────────────────
$result = Set-AuthenticodeSignature `
    -FilePath        $ExePath `
    -Certificate     $signingCert `
    -HashAlgorithm   SHA256 `
    -TimestampServer 'https://timestamp.digicert.com'

if ($result.Status -eq 'Valid') {
    Write-Host "`n  SUCCESS — EXE signed." -ForegroundColor Green
} else {
    Write-Error "Code signing failed with status: '$($result.Status)'"
    Write-Host ($result | Format-List | Out-String)
    exit 1
}

Write-Host ""
Write-Host "Done." -ForegroundColor Green
Write-Host "  Distribute: FieldPulse-SIP-Readiness.exe  (single file - no .bat or .ps1 needed)" -ForegroundColor Green
Write-Host "  Location  : $ExePath" -ForegroundColor Green
Write-Host ""
exit 0
