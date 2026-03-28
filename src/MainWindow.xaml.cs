using System.Collections.ObjectModel;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Media;

namespace FieldPulseSIP;

public partial class MainWindow : Window
{
    // ── Webhook config ─────────────────────────────────────────────
    // SECURITY: For production, consider loading from app.config or environment
    // PLACEHOLDER: Replaced by GitHub Actions during build
    private const string WebhookUrl    = "{{WEBHOOK_URL}}";
    private const string WebhookSecret = "{{WEBHOOK_SECRET}}";

    // ── Timeouts & Limits ─────────────────────────────────────────
    private const int TcpProbeTimeoutMs   = 1500;   // Timeout for TCP connectivity probes
    private const int HttpRequestTimeoutS = 30;     // Timeout for webhook HTTP request
    private const int PingCount           = 5;      // Number of ICMP pings for latency test
    private const int PingTimeoutMs       = 2000;   // Timeout per ping
    private const int MaxLatencyGoodMs    = 100;    // RTT threshold for PASS
    private const int MaxLatencyWarnMs    = 150;    // RTT threshold for WARN
    private const int MaxJitterGoodMs     = 20;     // Jitter threshold for PASS
    private const int MaxJitterWarnMs     = 30;     // Jitter threshold for WARN

    // ── Required IPs ───────────────────────────────────────────────
    private static readonly string[] HttpIPs =
        ["75.98.50.201", "207.254.80.55", "70.42.44.55", "75.98.50.55", "216.24.144.55"];

    private static readonly string[] SipIPs =
        ["54.172.60.0", "54.172.60.1", "54.172.60.2", "54.172.60.3",
         "54.244.51.0", "54.244.51.1", "54.244.51.2", "54.244.51.3"];

    private static readonly string[] RtpIPs =
        ["168.86.128.1", "168.86.150.1", "168.86.191.1"];

    // ── SIP phone OUI table ────────────────────────────────────────
    private static readonly Dictionary<string, string> SipOuis = new(StringComparer.OrdinalIgnoreCase)
    {
        ["80:5E:C0"] = "Yealink",       ["00:15:65"] = "Yealink",   ["DC:2C:6E"] = "Yealink",
        ["64:16:7F"] = "Polycom",        ["00:04:F2"] = "Polycom",
        ["00:0B:82"] = "Grandstream",    ["C0:74:AD"] = "Grandstream",
        ["00:1B:54"] = "Cisco IP Phone", ["D8:96:95"] = "Cisco IP Phone",
        ["F8:B1:56"] = "Cisco IP Phone", ["00:14:6A"] = "Cisco IP Phone",
        ["00:04:13"] = "Snom",           ["00:1A:E8"] = "Snom",
        ["00:A8:59"] = "Fanvil",         ["9C:28:EF"] = "Fanvil",
        ["00:30:48"] = "Obihai",
        ["00:04:0D"] = "Avaya",          ["00:1B:4F"] = "Avaya",
        ["08:00:0F"] = "Mitel",          ["00:90:7A"] = "Mitel",
    };

    // ── State ──────────────────────────────────────────────────────
    public ObservableCollection<CheckResult> Results { get; } = [];
    private readonly List<string> _reportLines = [];
    private string  _localIP  = "";
    private string  _publicIP = "";
    private string  _gateway  = "";
    private bool    _checksRan = false;
    private OnboardingData? _lastOnboarding;
    private Dictionary<string, bool> _tcpCache = [];
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(30) };

    // ── IsManualActionVisible property (bound to summary panel) ───
    public bool IsManualActionVisible { get; set; } = true;

    // ── Constructor ────────────────────────────────────────────────
    public MainWindow()
    {
        InitializeComponent();
        DataContext = this;
        lblMeta.Text = $"  Computer: {Environment.MachineName}   |   User: {Environment.UserName}   |   Date: {DateTime.Now:yyyy-MM-dd HH:mm}";

        // Wire ResultTemplateSelector to the resource
        if (Resources.Contains("ResultSelector") is false &&
            Application.Current.Resources["ResultSelector"] is ResultTemplateSelector sel)
        {
            sel.SectionTemplate = (DataTemplate)Application.Current.Resources["SectionTemplate"];
            sel.ResultTemplate  = (DataTemplate)Application.Current.Resources["ResultCardTemplate"];
        }
    }

    // ── Run Checks ─────────────────────────────────────────────────
    private async void BtnRun_Click(object sender, RoutedEventArgs e)
    {
        ResetState();
        btnRun.IsEnabled  = false;
        btnSend.IsEnabled = false;
        btnSave.IsEnabled = false;
        pnlWelcome.Visibility  = Visibility.Collapsed;
        resultsPanel.Visibility = Visibility.Visible;
        progressBar.IsIndeterminate = true;

        await RunChecks();

        progressBar.IsIndeterminate = false;
        progressBar.Value = 100;
        btnRun.IsEnabled  = true;
        btnSend.IsEnabled = true;
        btnSave.IsEnabled = true;
        _checksRan = true;
    }

    private void ResetState()
    {
        Results.Clear();
        _reportLines.Clear();
        _localIP = _publicIP = _gateway = "";
        _checksRan = false;
        _lastOnboarding = null;
        _tcpCache  = [];
        pnlSummary.Visibility = Visibility.Collapsed;
    }

    // ── All checks ─────────────────────────────────────────────────
    private async Task RunChecks()
    {
        // ── Check 1: Network adapters ─────────────────────────────
        SetStatus("Checking your internet connection...", 5);
        AddSection("1.  YOUR INTERNET CONNECTION");
        await RunCheck1();

        // ── Check 2: IP Connectivity (parallel) ──────────────────
        SetStatus("Connecting to FieldPulse servers...", 18);
        AddSection("2.  CONNECTING TO FIELDPULSE");
        await RunCheck2();

        // ── Check 2b: Latency & Jitter ───────────────────────────
        SetStatus("Measuring connection speed...", 52);
        AddSection("3.  CONNECTION SPEED & QUALITY");
        await RunCheck2b();

        // ── Check 3: Router ──────────────────────────────────────
        SetStatus("Checking your router...", 65);
        AddSection("4.  YOUR ROUTER");
        await RunCheck3();

        // ── Check 4: Device discovery ────────────────────────────
        SetStatus("Looking for phones on your network...", 85);
        AddSection("5.  PHONES ON YOUR NETWORK");
        await RunCheck4();

        // ── Summary ───────────────────────────────────────────────
        ShowSummary();
        SetStatus("All done!  Click  Send to FieldPulse  to share your results.", 100);
    }

    // ── Check 1 implementation ─────────────────────────────────────
    private async Task RunCheck1()
    {
        await Task.Run(() =>
        {
            var interfaces = NetworkInterface.GetAllNetworkInterfaces()
                .Where(n => n.OperationalStatus == OperationalStatus.Up &&
                            n.NetworkInterfaceType != NetworkInterfaceType.Loopback &&
                            n.NetworkInterfaceType != NetworkInterfaceType.Tunnel)
                .ToList();

            var wired    = interfaces.Where(n => n.NetworkInterfaceType is
                NetworkInterfaceType.Ethernet or NetworkInterfaceType.GigabitEthernet or
                NetworkInterfaceType.FastEthernetFx or NetworkInterfaceType.FastEthernetT).ToList();
            var wireless = interfaces.Where(n => n.NetworkInterfaceType == NetworkInterfaceType.Wireless80211).ToList();

            if (wired.Count > 0)
                foreach (var a in wired)
                    AddResult("Wired connection found", $"Your computer has a wired (Ethernet) connection — this is ideal for phone service. ({a.Name})", "PASS");
            else
                AddResult("No wired connection detected", "SIP phones work best with a wired (Ethernet) connection. If possible, connect phones directly to your router with a network cable.", "WARN");

            foreach (var a in wireless)
                AddResult("Wi-Fi connection found", $"Your computer is connected via Wi-Fi. Phones should use a wired connection for the best call quality. ({a.Name})", "INFO");

            // Gather addresses
            var ipConfig = NetworkInterface.GetAllNetworkInterfaces()
                .Where(n => n.OperationalStatus == OperationalStatus.Up)
                .SelectMany(n => n.GetIPProperties().UnicastAddresses)
                .FirstOrDefault(a => a.Address.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork
                                  && !IPAddress.IsLoopback(a.Address));

            _localIP = ipConfig?.Address.ToString() ?? "Unknown";

            var gw = NetworkInterface.GetAllNetworkInterfaces()
                .Where(n => n.OperationalStatus == OperationalStatus.Up)
                .SelectMany(n => n.GetIPProperties().GatewayAddresses)
                .FirstOrDefault(g => g.Address.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork &&
                                     !g.Address.Equals(IPAddress.Any));
            _gateway = gw?.Address.ToString() ?? "";
        });

        // Public IP (awaitable)
        try
        {
            using var cts = new CancellationTokenSource(3000);
            _publicIP = (await Http.GetStringAsync("https://api.ipify.org", cts.Token)).Trim();
        }
        catch { _publicIP = "Could not determine"; }

        AddResult("Your network information", $"These details help FieldPulse configure your phones. Local IP: {_localIP} | Router: {_gateway} | Public IP: {_publicIP}", "INFO");
    }

    // ── Check 2 implementation (parallel TCP probes) ───────────────
    private async Task RunCheck2()
    {
        var probes = new List<(string IP, int Port, string Type)>();
        foreach (var ip in HttpIPs) { probes.Add((ip, 80, "HTTP")); probes.Add((ip, 443, "HTTP")); }
        foreach (var ip in SipIPs)  { probes.Add((ip, 5060, "SIP")); probes.Add((ip, 5061, "SIP")); }
        foreach (var ip in RtpIPs)  { probes.Add((ip, 10000, "RTP")); }

        _tcpCache = await RunParallelTcpProbes(probes, TcpProbeTimeoutMs);
        SetStatus("Processing connectivity results...", 40);

        bool allReach = true;

        foreach (var ip in HttpIPs)
        {
            bool ok = _tcpCache.GetValueOrDefault($"{ip}:80") || _tcpCache.GetValueOrDefault($"{ip}:443");
            if (ok) AddResult($"Web server connected", $"Successfully reached FieldPulse web server. (IP: {ip})", "PASS");
            else  { AddResult($"Web server blocked", $"Cannot connect to a FieldPulse web server. Your IT team may need to allow access in the firewall. (IP: {ip}, ports 80/443)", "FAIL"); allReach = false; }
        }
        foreach (var ip in SipIPs)
        {
            bool p60 = _tcpCache.GetValueOrDefault($"{ip}:5060");
            bool p61 = _tcpCache.GetValueOrDefault($"{ip}:5061");
            if (p60 || p61) AddResult($"Phone server connected", $"Successfully reached FieldPulse phone server. (IP: {ip})", "PASS");
            else           { AddResult($"Phone server blocked", $"Cannot connect to a FieldPulse phone server. Your IT team may need to open ports 5060/5061 in the firewall. (IP: {ip})", "FAIL"); allReach = false; }
        }
        foreach (var ip in RtpIPs)
        {
            bool ok = _tcpCache.GetValueOrDefault($"{ip}:10000");
            if (ok) AddResult($"Audio server connected", $"Successfully reached FieldPulse audio server. (IP: {ip})", "PASS");
            else    AddResult($"Audio server test inconclusive", $"Could not confirm audio server — this is usually OK and does not mean a problem. (IP: {ip}, UDP port 10000)", "WARN");
        }

        if (!allReach)
            AddResult("Some FieldPulse servers are blocked", "Share this report with your IT team — they will need to update your firewall to allow these connections.", "FAIL");
        else
            AddResult("All FieldPulse servers reachable", "Your network can connect to everything needed for phone service.", "PASS");
    }

    private static async Task<Dictionary<string, bool>> RunParallelTcpProbes(
        IEnumerable<(string IP, int Port, string Type)> probes, int timeoutMs)
    {
        var tasks = probes.Select(async p =>
        {
            bool ok = false;
            try
            {
                using var tcp = new TcpClient();
                var connect = tcp.ConnectAsync(p.IP, p.Port);
                ok = await Task.WhenAny(connect, Task.Delay(timeoutMs)) == connect && !connect.IsFaulted;
            }
            catch { }
            return (Key: $"{p.IP}:{p.Port}", Ok: ok);
        });

        var results = await Task.WhenAll(tasks);
        return results.ToDictionary(r => r.Key, r => r.Ok);
    }

    // ── Check 2b implementation (latency) ──────────────────────────
    private async Task RunCheck2b()
    {
        if (!string.IsNullOrEmpty(_gateway))
            await PingTest(_gateway, "Gateway");
        await PingTest(SipIPs[0], "FieldPulse SIP");
    }

    private async Task PingTest(string host, string label)
    {
        try
        {
            var rtts = new List<long>();
            using var ping = new Ping();
            for (int i = 0; i < 5; i++)
            {
                try
                {
                    var reply = await ping.SendPingAsync(host, PingTimeoutMs);
                    if (reply.Status == IPStatus.Success) rtts.Add(reply.RoundtripTime);
                }
                catch { }
                if (i < 4) await Task.Delay(200);
            }

            if (rtts.Count < 2)
            {
                AddResult($"Connection speed test inconclusive — {label}", "Could not measure speed — this is usually OK, your network security may be blocking the test.", "WARN");
                return;
            }

            double avg    = rtts.Average();
            long   jitter = rtts.Max() - rtts.Min();
            int    lost   = 5 - rtts.Count;

            string status2 = (avg <= MaxLatencyGoodMs && jitter <= MaxJitterGoodMs) ? "PASS"
                          : (avg <= MaxLatencyWarnMs && jitter <= MaxJitterWarnMs) ? "WARN" : "FAIL";

            string detail = status2 switch
            {
                "PASS" => $"Your connection is fast and stable — great for phone calls. (Speed: {avg:F0}ms, Stability: {jitter}ms)",
                "WARN" => $"Your connection is OK but could be better. Calls may have minor quality issues during heavy internet use. (Speed: {avg:F0}ms, Stability: {jitter}ms)",
                _      => $"Your connection may be too slow for reliable phone calls. Contact your internet provider about improving speed. (Speed: {avg:F0}ms, Stability: {jitter}ms)",
            };

            string label2 = status2 switch
            {
                "PASS" => $"Connection speed: Excellent — {label}",
                "WARN" => $"Connection speed: Fair — {label}",
                _      => $"Connection speed: Slow — {label}",
            };
            AddResult(label2, detail, status2);
            _reportLines.Add($"Latency {label}: {detail}");
        }
        catch
        {
            AddResult($"Connection speed test skipped — {label}", "Your network security prevented this test — this is usually not a problem.", "WARN");
        }
    }

    // ── Check 3 implementation (router) ────────────────────────────
    private async Task RunCheck3()
    {
        string routerBrand   = "Unknown";
        string routerAdminUrl = $"http://{_gateway}";

        try
        {
            using var cts = new CancellationTokenSource(2000);
            var resp = await Http.GetAsync(routerAdminUrl, cts.Token);
            var body = (await resp.Content.ReadAsStringAsync()).ToLower();
            var server = resp.Headers.Server?.ToString().ToLower() ?? "";
            var probe  = body + " " + server;

            routerBrand = probe switch
            {
                _ when probe.Contains("ubiquiti") || probe.Contains("unifi")   => "Ubiquiti",
                _ when probe.Contains("meraki")                                 => "Cisco Meraki",
                _ when probe.Contains("cisco")                                  => "Cisco",
                _ when probe.Contains("netgear")                                => "Netgear",
                _ when probe.Contains("asus")                                   => "ASUS",
                _ when probe.Contains("tp-link") || probe.Contains("tplink")   => "TP-Link",
                _ when probe.Contains("linksys")                                => "Linksys",
                _ when probe.Contains("fortinet") || probe.Contains("fortigate")=> "Fortinet FortiGate",
                _ when probe.Contains("sonicwall")                              => "SonicWall",
                _ when probe.Contains("mikrotik") || probe.Contains("routeros") => "MikroTik",
                _ when probe.Contains("pfsense")                                => "pfSense",
                _ when probe.Contains("opnsense")                               => "OPNsense",
                _ when probe.Contains("ruckus")                                 => "Ruckus",
                _ when probe.Contains("watchguard")                             => "WatchGuard",
                _                                                               => "Unknown",
            };
        }
        catch { }

        AddResult($"Router identified", $"Your router ({routerBrand}) is at address {_gateway}. FieldPulse may need this info to help with setup.", "INFO");

        // SIP ports (use cached results from Check 2)
        bool sip60 = _tcpCache.GetValueOrDefault($"{SipIPs[0]}:5060");
        bool sip61 = _tcpCache.GetValueOrDefault($"{SipIPs[0]}:5061");
        if (sip60 || sip61)
            AddResult("Router allows phone traffic", "Your router is letting phone connections through — no changes needed.", "PASS");
        else
            AddResult("Router is blocking phone traffic", "Your router needs to be configured to allow phone connections. Share this report with your IT team or FieldPulse rep. (Ports 5060/5061 need to be opened)", "FAIL");

        // SIP ALG guidance
        string sipAlgSteps = routerBrand switch
        {
            "Ubiquiti"        => "Config > Routing & Firewall > ALG > uncheck SIP",
            "Cisco Meraki"    => "Security & SD-WAN > Firewall > uncheck SIP ALG",
            "Cisco"           => "Firewall > Advanced > Application Inspection > remove 'sip'",
            "Netgear"         => "Advanced > WAN Setup > uncheck 'Disable SIP ALG'",
            "ASUS"            => "Advanced Settings > WAN > NAT Passthrough > SIP Passthrough: Disable",
            "TP-Link"         => "Advanced > NAT Forwarding > ALG > uncheck SIP",
            "Linksys"         => "Security > Apps and Gaming > SIP ALG: Disable",
            "Fortinet FortiGate" => "VoIP > SIP > disable SIP session helper",
            "SonicWall"       => "VoIP > Settings > uncheck 'Enable SIP Transformations'",
            "MikroTik"        => "IP > Firewall > Service Ports > disable 'sip'",
            "pfSense"         => "System > Advanced > Firewall & NAT > uncheck 'Enable SIP Proxy'",
            "OPNsense"        => "Firewall > Settings > Advanced > uncheck 'Disable SIP proxy'",
            "WatchGuard"      => "Firewall Policies > Application Control > remove SIP ALG",
            _                 => $"Log into {routerAdminUrl} and search for 'SIP ALG', 'SIP Helper', or 'VoIP ALG'  —  disable it",
        };
        AddResult("Router setting may interfere with calls", $"Most routers have a feature called 'SIP ALG' that can cause dropped calls. Your IT team should disable it. Steps for your {routerBrand} router: {sipAlgSteps}", "WARN");

        // Required ports note
        _reportLines.Add("");
        _reportLines.Add($"ROUTER PORTS REQUIRED (apply in router admin at {routerAdminUrl})");
        _reportLines.Add("  Outbound  TCP/UDP 5060   -> FieldPulse SIP IPs (SIP signaling)");
        _reportLines.Add("  Outbound  TCP     5061   -> FieldPulse SIP IPs (SIP TLS)");
        _reportLines.Add("  Outbound  UDP 10000-20000 -> 168.86.128.0/18   (RTP media)");

        AddResult("Router may need configuration",
            "Your IT team may need to open specific ports on your router for phone service. This is included in the report sent to FieldPulse. (TCP/UDP 5060, TCP 5061, UDP 10000–20000)", "INFO");

        // Windows Firewall (admin only)
        bool isAdmin = new System.Security.Principal.WindowsPrincipal(
            System.Security.Principal.WindowsIdentity.GetCurrent())
            .IsInRole(System.Security.Principal.WindowsBuiltInRole.Administrator);

        if (!isAdmin)
            AddResult("Computer firewall (partial check)", "For a complete firewall check, right-click the app and choose 'Run as Administrator'. This is optional.", "WARN");
        else
        {
            try
            {
                var proc = Process.Start(new ProcessStartInfo("netsh",
                    "advfirewall firewall show rule name=all dir=out action=block")
                { RedirectStandardOutput = true, UseShellExecute = false, CreateNoWindow = true });
                string fw = proc?.StandardOutput.ReadToEnd() ?? "";
                proc?.WaitForExit();

                bool hasConflict = HttpIPs.Concat(SipIPs).Any(ip => fw.Contains(ip));
                if (hasConflict)
                    AddResult("Computer firewall is blocking FieldPulse", "This computer's firewall has rules that block FieldPulse servers. Your IT team needs to update the Windows Firewall settings.", "FAIL");
                else
                    AddResult("Computer firewall looks good", "No firewall rules on this computer are blocking FieldPulse phone service.", "PASS");
            }
            catch
            {
                AddResult("Computer firewall check skipped", "Could not check the firewall on this computer — this is OK, FieldPulse will verify during setup.", "INFO");
            }
        }
    }

    // ── Check 4 implementation (device discovery) ──────────────────
    private async Task RunCheck4()
    {
        // DNS test
        try
        {
            var addresses = await Dns.GetHostAddressesAsync("sip.twilio.com");
            var first = addresses.FirstOrDefault()?.ToString() ?? "?";
            AddResult("Internet name lookup working", $"Your network can look up server addresses — required for phone service to connect. (sip.twilio.com = {first})", "PASS");
        }
        catch
        {
            AddResult("Internet name lookup failed", "Your network cannot look up server addresses (DNS). This must be fixed for phone service to work. Contact your IT team or internet provider.", "FAIL");
        }

        // ARP table
        var devices = await Task.Run(GetArpTable);
        var sipFound = devices.Where(d => !string.IsNullOrEmpty(d.Vendor)).ToList();

        _reportLines.Add("\nDEVICE DISCOVERY (ARP TABLE)");
        _reportLines.Add($"{"IP Address",-20}{"MAC Address",-20}Vendor");
        _reportLines.Add(new string('-', 60));
        foreach (var d in devices)
            _reportLines.Add($"{d.IP,-20}{d.MAC,-20}{d.Vendor}");

        if (sipFound.Count > 0)
        {
            string list = string.Join("  |  ", sipFound.Select(d => $"{d.Vendor} at {d.IP}"));
            AddResult($"Found {sipFound.Count} phone(s) on your network", $"We detected these phones already connected: {list}", "PASS");
            _reportLines.Add("\nDETECTED SIP PHONES");
            foreach (var d in sipFound) _reportLines.Add($"  {d.IP}  {d.MAC}  ({d.Vendor})");
        }
        else
        {
            AddResult("No phones detected yet", "Don't worry — phones may be turned off, not yet connected, or a different brand. FieldPulse will help identify them during setup.", "INFO");
        }

        AddResult($"{devices.Count} device(s) found on your network", "FieldPulse will use this to help configure your phones. Full details are included in the report.", "INFO");
    }

    private List<(string IP, string MAC, string Vendor)> GetArpTable()
    {
        var result = new List<(string, string, string)>();
        try
        {
            var proc = Process.Start(new ProcessStartInfo("arp", "-a")
                { RedirectStandardOutput = true, UseShellExecute = false, CreateNoWindow = true });
            var output = proc?.StandardOutput.ReadToEnd() ?? "";
            proc?.WaitForExit();

            foreach (var line in output.Split('\n'))
            {
                var m = Regex.Match(line, @"(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})\s+([\w-]{11,17})\s+dynamic");
                if (!m.Success) continue;
                string ip  = m.Groups[1].Value;
                string mac = m.Groups[2].Value.ToUpper().Replace("-", ":");
                string oui = string.Join(":", mac.Split(':').Take(3));
                SipOuis.TryGetValue(oui, out string? vendor);
                result.Add((ip, mac, vendor ?? ""));
            }
        }
        catch { }
        return result;
    }

    // ── Summary ────────────────────────────────────────────────────
    private void ShowSummary()
    {
        int pass = Results.Count(r => r.Status == "PASS");
        int fail = Results.Count(r => r.Status == "FAIL");
        int warn = Results.Count(r => r.Status == "WARN");

        _reportLines.Add($"\n{pass} PASS  |  {warn} WARN  |  {fail} FAIL");

        pnlSummary.Visibility = Visibility.Visible;

        if (fail > 0)
        {
            pnlSummary.Background    = new SolidColorBrush(Color.FromRgb(255, 235, 233));
            pnlSummary.BorderBrush   = new SolidColorBrush(Color.FromRgb(207, 34, 46));
            lblSummaryTitle.Text     = $"✗  {fail} issue(s) need to be fixed before your phones will work.";
            lblSummaryTitle.Foreground = new SolidColorBrush(Color.FromRgb(207, 34, 46));
        }
        else if (warn > 2)
        {
            pnlSummary.Background    = new SolidColorBrush(Color.FromRgb(255, 248, 197));
            pnlSummary.BorderBrush   = new SolidColorBrush(Color.FromRgb(154, 103, 0));
            lblSummaryTitle.Text     = "⚠  A few things may need attention — FieldPulse will review with you.";
            lblSummaryTitle.Foreground = new SolidColorBrush(Color.FromRgb(154, 103, 0));
        }
        else
        {
            pnlSummary.Background    = new SolidColorBrush(Color.FromRgb(218, 251, 225));
            pnlSummary.BorderBrush   = new SolidColorBrush(Color.FromRgb(26, 127, 55));
            lblSummaryTitle.Text     = "✓  Everything looks good — you're ready for FieldPulse phone service!";
            lblSummaryTitle.Foreground = new SolidColorBrush(Color.FromRgb(26, 127, 55));
        }

        lblSummaryDetail.Text = $"{pass} passed  ·  {warn} needs review  ·  {fail} needs action";
    }

    // ── Send to FieldPulse ─────────────────────────────────────────
    private async void BtnSend_Click(object sender, RoutedEventArgs e)
    {
        if (!_checksRan) return;

        var dlg = new SubmissionDialog { Owner = this };
        if (dlg.ShowDialog() != true) return;

        var onboarding = dlg.ResultData!;
        string customerName = string.IsNullOrWhiteSpace(txtCompanyName.Text)
            ? "Unknown Customer"
            : Regex.Replace(txtCompanyName.Text.Trim(), @"[^\x20-\x7E]", "");

        // ── Pre-send security scan ────────────────────────────────
        var secWarnings = ScanReportContent(customerName, onboarding);
        if (secWarnings.Count > 0)
        {
            string list = string.Join("\n", secWarnings.Select(w => $"  \u2022 {w}"));
            var choice = MessageBox.Show(
                $"Suspicious content was detected in the submission:\n\n{list}\n\n" +
                "This may indicate an injection attempt in a customer-entered field.\n\n" +
                "Send anyway?",
                "Security Warning", MessageBoxButton.YesNo, MessageBoxImage.Warning);
            if (choice != MessageBoxResult.Yes) return;
        }

        _lastOnboarding = onboarding;

        int pass = Results.Count(r => r.Status == "PASS");
        int fail = Results.Count(r => r.Status == "FAIL");
        int warn = Results.Count(r => r.Status == "WARN");

        string reportText = BuildReport(onboarding);
        string reportHtml = BuildHtmlReport(onboarding);
        string reportDate = DateTime.Now.ToString("yyyy-MM-dd HH:mm");

        // Build CSV string + base64 for email attachment
        string csvContent  = BuildCsvString(onboarding.PhoneCSV);
        string csvBase64   = csvContent.Length > 0
            ? Convert.ToBase64String(Encoding.UTF8.GetBytes(csvContent))
            : "";
        string csvFilename = csvContent.Length > 0
            ? $"FieldPulse-Phones-{customerName}-{DateTime.Now:yyyyMMdd}.csv"
            : "";

        var payload = new Dictionary<string, object?>
        {
            ["customer"]                  = customerName,
            ["computer"]                  = Environment.MachineName,
            ["date"]                      = reportDate,
            ["local_ip"]                  = _localIP,
            ["public_ip"]                 = _publicIP,
            ["gateway"]                   = _gateway,
            ["pass_count"]                = pass,
            ["fail_count"]                = fail,
            ["warn_count"]                = warn,
            ["phone_count"]               = onboarding.PhoneCount,
            ["phone_count_text"]          = onboarding.PhoneCountText,
            ["phone_brand"]               = onboarding.PhoneBrand,
            ["phone_models"]              = onboarding.PhoneModels,
            ["config_type"]               = onboarding.ConfigType,
            ["mac_serials"]               = onboarding.MacSerials,
            ["config_notes"]              = onboarding.ConfigNotes,
            ["preferred_time"]            = onboarding.PreferredTime,
            ["attendees"]                 = onboarding.Attendees,
            ["confirmed_new_phones"]              = onboarding.ConfirmedNewPhones,
            ["confirmed_phones_released"]         = onboarding.ConfirmedPhonesReleased,
            ["confirmed_provisioning_passwords"]  = onboarding.ConfirmedProvisioningPasswords,
            ["confirmed_factory_reset"]           = onboarding.ConfirmedFactoryReset,
            ["confirmed_firmware"]                = onboarding.ConfirmedFirmware,
            ["phone_csv"]                 = onboarding.PhoneCSV is { Count: > 0 }
                                              ? JsonSerializer.Serialize(onboarding.PhoneCSV)
                                              : "",
            ["csv_base64"]                = csvBase64,
            ["csv_filename"]              = csvFilename,
            ["report"]                    = reportText,
            ["report_html"]               = reportHtml,
        };

        string jsonBody = JsonSerializer.Serialize(payload);

        // HMAC-SHA256 signature
        string sig;
        try
        {
            var key = Encoding.UTF8.GetBytes(WebhookSecret);
            var msg = Encoding.UTF8.GetBytes(jsonBody);
            sig = Convert.ToBase64String(HMACSHA256.HashData(key, msg));
        }
        catch (Exception ex)
        {
            MessageBox.Show($"Could not compute request signature.\n\nUse Save Report instead.\n\nError: {ex.Message}",
                "Signature Error", MessageBoxButton.OK, MessageBoxImage.Error);
            return;
        }

        btnSend.IsEnabled = false;
        btnSend.Content   = "  Sending...";
        SetStatus("Sending report to FieldPulse...", 100);

        try
        {
            string uri = $"{WebhookUrl}?sig={Uri.EscapeDataString(sig)}";
            using var content = new StringContent(jsonBody, Encoding.UTF8, "application/json");
            using var cts = new CancellationTokenSource(HttpRequestTimeoutS * 1000);
            var response = await Http.PostAsync(uri, content, cts.Token);
            string raw   = await response.Content.ReadAsStringAsync();

            using var doc = JsonDocument.Parse(raw);
            var statusValue = doc.RootElement.TryGetProperty("status", out var status) ? status.GetString() : null;

            if (statusValue == "ok")
            {
                btnSend.Content   = "✓  Sent!";
                btnSend.Background = new SolidColorBrush(Color.FromRgb(26, 127, 55));
                SetStatus("Report sent to FieldPulse team successfully.", 100);
                App.WriteAuditLog("SUBMISSION_SUCCESS", $"Customer: {customerName}, Pass: {pass}, Fail: {fail}, Warn: {warn}");
                MessageBox.Show("Your readiness report has been sent to the FieldPulse team.\n\nThey will review your results and contact you to schedule configuration.",
                    "Report Sent!", MessageBoxButton.OK, MessageBoxImage.Information);
            }
            else if (statusValue == "partial")
            {
                // Report saved to Drive but email notification failed
                btnSend.Content   = "✓  Saved";
                btnSend.Background = new SolidColorBrush(Color.FromRgb(154, 103, 0)); // Warning yellow
                string driveUrl = doc.RootElement.TryGetProperty("drive_url", out var url) ? url.GetString() ?? "" : "";
                SetStatus("Report saved to Drive (email notification pending).", 100);
                App.WriteAuditLog("SUBMISSION_PARTIAL", $"Customer: {customerName}, DriveUrl: {driveUrl}");
                MessageBox.Show("Your report was saved to FieldPulse's system, but the email notification failed to send.\n\nThe FieldPulse team will retrieve your report from their Drive folder and contact you shortly.",
                    "Report Saved", MessageBoxButton.OK, MessageBoxImage.Warning);
            }
            else if (statusValue == "duplicate")
            {
                // Duplicate submission detected
                btnSend.Content   = "✓  Already Sent";
                btnSend.Background = new SolidColorBrush(Color.FromRgb(87, 96, 106)); // Gray
                string driveUrl = doc.RootElement.TryGetProperty("drive_url", out var url2) ? url2.GetString() ?? "" : "";
                SetStatus("Report was already submitted.", 100);
                App.WriteAuditLog("SUBMISSION_DUPLICATE", $"Customer: {customerName}, ExistingUrl: {driveUrl}");
                MessageBox.Show("This report was already submitted recently.\n\nIf you need to send an updated report, please wait a few minutes and try again, or use Save Report to create a new file.",
                    "Already Submitted", MessageBoxButton.OK, MessageBoxImage.Information);
            }
            else
            {
                string msg = doc.RootElement.TryGetProperty("message", out var m) ? m.GetString()! : "Unexpected response from server.";
                App.WriteAuditLog("SUBMISSION_ERROR", $"Customer: {customerName}, Error: {msg}");
                throw new Exception(msg);
            }
        }
        catch (Exception ex)
        {
            App.WriteStructuredLog("ERROR", "BtnSend_Click.HttpPost", ex, $"Customer: {customerName}");
            btnSend.Content   = "✉   Send to FieldPulse";
            btnSend.IsEnabled = true;
            SetStatus("Send failed  —  please use Save Report and email manually.", 100);
            MessageBox.Show($"Could not send the report automatically.\n\nPlease use Save Report and email the file to your FieldPulse contact.\n\nError: {ex.Message}",
                "Send Failed", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
    }

    // ── Save Report ────────────────────────────────────────────────
    private void BtnSave_Click(object sender, RoutedEventArgs e)
    {
        if (!_checksRan) return;
        string html      = BuildHtmlReport(_lastOnboarding);
        string savePath  = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.Desktop),
            $"FieldPulse-SIP-Readiness-{DateTime.Now:yyyyMMdd-HHmm}.html");
        try
        {
            File.WriteAllText(savePath, html, Encoding.UTF8);
            MessageBox.Show($"Report saved to:\n{savePath}\n\nOpen it in any browser. Share with the FieldPulse team.",
                "Report Saved", MessageBoxButton.OK, MessageBoxImage.Information);
        }
        catch (Exception ex)
        {
            MessageBox.Show($"Could not save to Desktop.\n\n{ex.Message}",
                "Save Error", MessageBoxButton.OK, MessageBoxImage.Error);
        }
    }

    private void BtnClose_Click(object sender, RoutedEventArgs e) => Close();

    private void BtnUserGuide_Click(object sender, RoutedEventArgs e)
        => OpenEmbeddedPdf("FieldPulseSIP.Docs.USER-GUIDE.pdf", "USER-GUIDE.pdf", "User Guide");

    private void BtnITGuide_Click(object sender, RoutedEventArgs e)
        => OpenEmbeddedPdf("FieldPulseSIP.Docs.IT-ADMIN-GUIDE.pdf", "IT-ADMIN-GUIDE.pdf", "IT Admin Guide");

    private void OpenEmbeddedPdf(string resourceName, string fileName, string title)
    {
        try
        {
            var assembly = System.Reflection.Assembly.GetExecutingAssembly();
            using var stream = assembly.GetManifestResourceStream(resourceName);

            if (stream == null)
            {
                // Fallback to online documentation if PDF not embedded
                var psi = new System.Diagnostics.ProcessStartInfo
                {
                    FileName = "https://github.com/Deltronzero2020/FieldPulse-SIP-Readiness/releases/latest",
                    UseShellExecute = true
                };
                System.Diagnostics.Process.Start(psi);
                return;
            }

            // Extract to temp folder and open
            string tempPath = Path.Combine(Path.GetTempPath(), "FieldPulse-SIP-Docs");
            Directory.CreateDirectory(tempPath);
            string filePath = Path.Combine(tempPath, fileName);

            using (var fileStream = File.Create(filePath))
            {
                stream.CopyTo(fileStream);
            }

            var openPsi = new System.Diagnostics.ProcessStartInfo
            {
                FileName = filePath,
                UseShellExecute = true
            };
            System.Diagnostics.Process.Start(openPsi);
        }
        catch (Exception ex)
        {
            MessageBox.Show($"Could not open {title}.\n\n{ex.Message}",
                title, MessageBoxButton.OK, MessageBoxImage.Information);
        }
    }

    // ── Report builder ─────────────────────────────────────────────
    private string BuildReport(OnboardingData? onboarding = null)
    {
        string customerName = string.IsNullOrWhiteSpace(txtCompanyName.Text)
            ? "Unknown Customer" : txtCompanyName.Text.Trim();
        string divider = new('=', 60);
        string sub     = new('-', 60);

        var sb = new StringBuilder();
        sb.AppendLine(divider);
        sb.AppendLine("  FIELDPULSE ENGAGE  -  SIP READINESS REPORT");
        sb.AppendLine(divider);
        sb.AppendLine($"  Customer  : {customerName}");
        sb.AppendLine($"  Computer  : {Environment.MachineName}");
        sb.AppendLine($"  User      : {Environment.UserName}");
        sb.AppendLine($"  Date      : {DateTime.Now:yyyy-MM-dd HH:mm}");
        sb.AppendLine($"  Local IP  : {_localIP}");
        sb.AppendLine($"  Gateway   : {_gateway}");
        sb.AppendLine($"  Public IP : {_publicIP}");
        sb.AppendLine(divider);
        sb.AppendLine();
        foreach (var line in _reportLines) sb.AppendLine(line);

        if (onboarding != null)
        {
            sb.AppendLine();
            sb.AppendLine(divider);
            sb.AppendLine("  ONBOARDING INFORMATION");
            sb.AppendLine(sub);
            sb.AppendLine($"  Phone count    : {onboarding.PhoneCountText}");
            sb.AppendLine($"  Phone brand    : {onboarding.PhoneBrand}");
            sb.AppendLine($"  Phone model(s) : {onboarding.PhoneModels}");
            sb.AppendLine($"  Config type    : {onboarding.ConfigType}");
            sb.AppendLine($"  MAC / Serials  : {onboarding.MacSerials}");
            sb.AppendLine($"  Config notes   : {onboarding.ConfigNotes}");
            sb.AppendLine($"  Preferred time : {onboarding.PreferredTime}");
            sb.AppendLine($"  Attendee(s)    : {onboarding.Attendees}");
            sb.AppendLine(sub);
            sb.AppendLine("  CUSTOMER CONFIRMATIONS");
            sb.AppendLine($"  Brand new phones (no prev. provider) : {(onboarding.ConfirmedNewPhones ? "YES" : "NO")}");
            sb.AppendLine($"  Phones released from auto-prov.      : {(onboarding.ConfirmedPhonesReleased ? "YES" : "NO")}");
            sb.AppendLine($"  Provisioning passwords cleared       : {(onboarding.ConfirmedProvisioningPasswords ? "YES" : "NO")}");
            sb.AppendLine($"  Phones factory reset                 : {(onboarding.ConfirmedFactoryReset ? "YES" : "NO")}");
            sb.AppendLine($"  Firmware updated                     : {(onboarding.ConfirmedFirmware ? "YES" : "NO")}");
            sb.AppendLine(divider);

            if (onboarding.PhoneCSV is { Count: > 0 })
            {
                sb.AppendLine();
                sb.AppendLine(new('=', 78));
                sb.AppendLine($"  PHONE INVENTORY  ({onboarding.PhoneCSV.Count} phone(s) from uploaded CSV)");
                sb.AppendLine($"  {new string('-', 76)}");
                sb.AppendLine($"  {"#",-5}{"Model",-21}{"MAC Address",-20}{"Serial",-16}{"Ext",-7}Label");
                sb.AppendLine($"  {new string('-', 76)}");
                int n = 1;
                foreach (var ph in onboarding.PhoneCSV)
                {
                    sb.AppendLine($"  {n,-5}{ph.PhoneModel,-21}{ph.MACAddress,-20}{ph.SerialNumber,-16}{ph.Extension,-7}{ph.LineLabel}");
                    n++;
                }
                sb.AppendLine(new('=', 78));
            }
        }
        else
        {
            sb.AppendLine();
            sb.AppendLine(divider);
            sb.AppendLine("  MANUAL ACTION STILL REQUIRED");
            sb.AppendLine("  - Disable SIP ALG in router (SIP Helper / VoIP ALG)");
            sb.AppendLine("  - Contact former phone system provider to release devices");
            sb.AppendLine("  - Factory reset SIP phones before FieldPulse configuration");
            sb.AppendLine("  - Update SIP phone firmware to latest stable version");
            sb.AppendLine(divider);
        }

        return sb.ToString();
    }

    // ── Pre-send security scan ─────────────────────────────────────
    // Checks all free-text customer fields for injection patterns that could
    // be dangerous when the report is opened by the FieldPulse team.
    private static List<string> ScanReportContent(string customerName, OnboardingData ob)
    {
        var issues = new List<string>();

        var fields = new Dictionary<string, string>
        {
            ["Company name"]    = customerName,
            ["Phone count"]     = ob.PhoneCountText,
            ["Phone brand"]     = ob.PhoneBrand,
            ["Phone model(s)"]  = ob.PhoneModels,
            ["Config type"]     = ob.ConfigType,
            ["MAC / Serials"]   = ob.MacSerials,
            ["Config notes"]    = ob.ConfigNotes,
            ["Preferred time"]  = ob.PreferredTime,
            ["Attendees"]       = ob.Attendees,
        };

        foreach (var (field, value) in fields)
        {
            if (string.IsNullOrEmpty(value)) continue;

            if (Regex.IsMatch(value, @"^[=+\-@|]", RegexOptions.Multiline))
                issues.Add($"{field}: formula/CSV injection pattern detected");

            if (Regex.IsMatch(value, @"(?i)^cmd\s*\|", RegexOptions.Multiline))
                issues.Add($"{field}: DDE injection pattern detected");

            if (Regex.IsMatch(value, @"<\s*(script|iframe|img|svg|object|embed|link|meta|form)\b", RegexOptions.IgnoreCase))
                issues.Add($"{field}: HTML tag injection pattern detected");

            if (Regex.IsMatch(value, @"(?i)(javascript|vbscript|data)\s*:"))
                issues.Add($"{field}: script URI injection pattern detected");

            if (value.IndexOfAny(['\r', '\n']) >= 0 &&
                Regex.IsMatch(value, @"\r?\n.*(Content-Type|Set-Cookie|Location)\s*:", RegexOptions.IgnoreCase))
                issues.Add($"{field}: HTTP header injection pattern detected");
        }

        return issues;
    }

    // ── HTML report builder ────────────────────────────────────────
    private string BuildHtmlReport(OnboardingData? onboarding)
    {
        string customer = string.IsNullOrWhiteSpace(txtCompanyName.Text)
            ? "Unknown Customer" : txtCompanyName.Text.Trim();

        int pass = Results.Count(r => r.Status == "PASS");
        int warn = Results.Count(r => r.Status == "WARN");
        int fail = Results.Count(r => r.Status == "FAIL");

        static string Esc(string s) => System.Net.WebUtility.HtmlEncode(s);

        static string Badge(string status)
        {
            var (bg, fg, label) = status switch
            {
                "PASS" => ("#DAFBE1", "#1A7F37", "&#10003;&nbsp; PASS"),
                "FAIL" => ("#FFEBE9", "#CF222E", "&#10007;&nbsp; FAIL"),
                "WARN" => ("#FFF8C5", "#9A6700", "!&nbsp; WARN"),
                "INFO" => ("#DDF4FF", "#0550AE", "i&nbsp; INFO"),
                _      => ("#F6F8FA", "#57606A", "&middot;"),
            };
            return $"<span style=\"background:{bg};color:{fg};padding:3px 10px;border-radius:10px;" +
                   $"font-size:11px;font-weight:700;white-space:nowrap\">{label}</span>";
        }

        static string Dot(bool v) => v
            ? "<span style=\"color:#1A7F37;font-weight:700\">&#10003; Yes</span>"
            : "<span style=\"color:#CF222E;font-weight:700\">&#10007; No</span>";

        // CSS has no dynamic content — plain raw string avoids all brace-escaping issues
        const string css = """
              *{box-sizing:border-box;margin:0;padding:0}
              body{font-family:'Segoe UI',Arial,sans-serif;background:#F6F8FA;color:#1C2226;padding:24px}
              .wrap{max-width:860px;margin:0 auto}
              .header{background:#00034D;color:#fff;padding:28px 32px;border-radius:8px 8px 0 0}
              .header h1{font-size:20px;font-weight:700;margin-bottom:4px}
              .header p{font-size:12px;color:#8899CC;margin:0}
              .meta{background:#EAECF0;padding:10px 32px;font-size:12px;color:#57606A;border-bottom:1px solid #D0D7DE}
              .body{background:#fff;padding:24px 32px;border:1px solid #D0D7DE;border-top:none;border-radius:0 0 8px 8px}
              .section{margin:24px 0 10px;display:flex;align-items:center;gap:10px}
              .section-title{font-size:11px;font-weight:700;color:#00034D;text-transform:uppercase;letter-spacing:.8px;white-space:nowrap}
              .section-line{flex:1;height:1px;background:#D0D7DE}
              table{width:100%;border-collapse:collapse;margin-bottom:16px}
              td,th{padding:10px 12px;font-size:13px;vertical-align:top;border-bottom:1px solid #EAECF0}
              th{font-size:11px;font-weight:700;color:#57606A;text-align:left;background:#F6F8FA;border-bottom:2px solid #D0D7DE}
              tr:last-child td{border-bottom:none}
              .result-cat{font-weight:600;color:#1C2226}
              .result-detail{color:#57606A;font-size:12px;margin-top:3px}
              .accent{width:4px;border-radius:4px;padding:0 !important}
              .kv td:first-child{width:200px;font-weight:600;color:#57606A;font-size:12px}
              .kv td:last-child{font-size:13px}
              .summary{padding:14px 18px;border-radius:6px;margin-bottom:20px;font-weight:600}
              .inv th,.inv td{font-size:12px}
              @media print{body{padding:0}}
            """;

        var sb = new StringBuilder();
        sb.Append($"""
            <!DOCTYPE html>
            <html lang="en">
            <head>
            <meta charset="utf-8"/>
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'"/>
            <meta name="viewport" content="width=device-width,initial-scale=1"/>
            <title>FieldPulse SIP Readiness Report &mdash; {Esc(customer)}</title>
            <style>
            {css}
            </style>
            </head>
            <body>
            <div class="wrap">
              <div class="header">
                <h1>FieldPulse &mdash; SIP Readiness Report</h1>
                <p>SIP Phone Registration Readiness Check &nbsp;&bull;&nbsp; v2.0</p>
              </div>
              <div class="meta">
                Customer: <strong>{Esc(customer)}</strong> &nbsp;&bull;&nbsp;
                Computer: <strong>{Esc(Environment.MachineName)}</strong> &nbsp;&bull;&nbsp;
                User: <strong>{Esc(Environment.UserName)}</strong> &nbsp;&bull;&nbsp;
                Date: <strong>{DateTime.Now:yyyy-MM-dd HH:mm}</strong>
              </div>
              <div class="body">
            """);

        // Summary banner
        string sumBg, sumColor, sumText;
        if (fail > 0)      { sumBg = "#FFEBE9"; sumColor = "#CF222E"; sumText = $"&#10007; Action required &mdash; {fail} issue(s) must be resolved before SIP phones can register."; }
        else if (warn > 2) { sumBg = "#FFF8C5"; sumColor = "#9A6700"; sumText = "&#9888; Some warnings need attention before onboarding."; }
        else               { sumBg = "#DAFBE1"; sumColor = "#1A7F37"; sumText = "&#10003; Your environment looks ready!"; }

        sb.Append($"""
              <div class="summary" style="background:{sumBg};color:{sumColor};border:1px solid {sumColor}40">
                {sumText} &nbsp; &mdash; &nbsp; {pass} PASS &nbsp; {warn} WARN &nbsp; {fail} FAIL
              </div>
            """);

        // Network info
        sb.Append("""
              <div class="section"><span class="section-title">Network Info</span><div class="section-line"></div></div>
              <table class="kv">
            """);
        sb.Append($"<tr><td>Local IP</td><td>{Esc(_localIP)}</td></tr>");
        sb.Append($"<tr><td>Public IP</td><td>{Esc(_publicIP)}</td></tr>");
        sb.Append($"<tr><td>Gateway</td><td>{Esc(_gateway)}</td></tr>");
        sb.Append("</table>");

        // Check results
        string? currentSection = null;
        foreach (var r in Results)
        {
            if (r.IsSection)
            {
                if (currentSection != null) sb.Append("</table>");
                currentSection = r.SectionTitle;
                sb.Append($"""
                      <div class="section"><span class="section-title">{Esc(r.SectionTitle)}</span><div class="section-line"></div></div>
                      <table>
                        <tr><th style="width:36%">Check</th><th>Detail</th><th style="width:100px;text-align:center">Result</th></tr>
                    """);
            }
            else
            {
                string accentColor = r.Status switch
                {
                    "PASS" => "#1A7F37", "FAIL" => "#CF222E", "WARN" => "#9A6700", _ => "#0550AE"
                };
                sb.Append($"""
                      <tr>
                        <td class="accent" style="background:{accentColor}"></td>
                        <td><div class="result-cat">{Esc(r.Category)}</div><div class="result-detail">{Esc(r.Detail)}</div></td>
                        <td style="text-align:center">{Badge(r.Status)}</td>
                      </tr>
                    """);
            }
        }
        if (currentSection != null) sb.Append("</table>");

        // Onboarding section
        if (onboarding != null)
        {
            sb.Append("""
                  <div class="section"><span class="section-title">Onboarding Information</span><div class="section-line"></div></div>
                  <table class="kv">
                """);
            void Row(string k, string v) => sb.Append($"<tr><td>{Esc(k)}</td><td>{Esc(v)}</td></tr>");
            Row("Phone count",    onboarding.PhoneCountText);
            Row("Phone brand",    onboarding.PhoneBrand);
            Row("Phone model(s)", onboarding.PhoneModels);
            Row("Config type",    onboarding.ConfigType);
            Row("MAC / Serials",  onboarding.MacSerials);
            Row("Preferred time", onboarding.PreferredTime);
            Row("Attendee(s)",    onboarding.Attendees);
            if (!string.IsNullOrWhiteSpace(onboarding.ConfigNotes))
                Row("Notes", onboarding.ConfigNotes);
            sb.Append("</table>");

            sb.Append("""
                  <div class="section"><span class="section-title">Customer Confirmations</span><div class="section-line"></div></div>
                  <table class="kv">
                """);
            sb.Append($"<tr><td>Brand new phones (not switching)</td><td>{Dot(onboarding.ConfirmedNewPhones)}</td></tr>");
            sb.Append($"<tr><td>Phones released from auto-provisioning</td><td>{Dot(onboarding.ConfirmedPhonesReleased)}</td></tr>");
            sb.Append($"<tr><td>Setup passwords cleared/provided</td><td>{Dot(onboarding.ConfirmedProvisioningPasswords)}</td></tr>");
            sb.Append($"<tr><td>Phones factory reset</td><td>{Dot(onboarding.ConfirmedFactoryReset)}</td></tr>");
            sb.Append($"<tr><td>Software updated</td><td>{Dot(onboarding.ConfirmedFirmware)}</td></tr>");
            sb.Append("</table>");

            if (onboarding.PhoneCSV is { Count: > 0 })
            {
                sb.Append($"""
                      <div class="section"><span class="section-title">Phone Inventory ({onboarding.PhoneCSV.Count} phones)</span><div class="section-line"></div></div>
                      <table class="inv">
                        <tr><th>#</th><th>Brand</th><th>Model</th><th>MAC Address</th><th>Serial</th><th>Ext</th><th>Label</th></tr>
                    """);
                int n = 1;
                foreach (var p in onboarding.PhoneCSV)
                    sb.Append($"<tr><td>{n++}</td><td>{Esc(p.Brand)}</td><td>{Esc(p.PhoneModel)}</td><td><code>{Esc(p.MACAddress)}</code></td><td>{Esc(p.SerialNumber)}</td><td>{Esc(p.Extension)}</td><td>{Esc(p.LineLabel)}</td></tr>");
                sb.Append("</table>");
            }
        }
        else
        {
            sb.Append("""
                  <div class="section"><span class="section-title">Manual Actions Still Required</span><div class="section-line"></div></div>
                  <ul style="margin:0 0 16px 20px;font-size:13px;line-height:2">
                    <li>Disable SIP ALG in router (SIP Helper / VoIP ALG)</li>
                    <li>Contact former phone system provider to release devices</li>
                    <li>Factory reset SIP phones before FieldPulse configuration</li>
                    <li>Update SIP phone firmware to latest stable version</li>
                  </ul>
                """);
        }

        sb.Append($"""
              <p style="font-size:11px;color:#8C959F;margin-top:24px;border-top:1px solid #EAECF0;padding-top:12px">
                Generated by FieldPulse SIP Readiness Check v2.0 &nbsp;&bull;&nbsp; {DateTime.Now:yyyy-MM-dd HH:mm}
              </p>
              </div>
            </div>
            </body>
            </html>
            """);

        return sb.ToString();
    }

    // ── CSV string builder ─────────────────────────────────────────
    private static string BuildCsvString(List<PhoneEntry>? phones)
    {
        if (phones is not { Count: > 0 }) return "";
        var sb = new StringBuilder();
        sb.AppendLine("Brand,PhoneModel,MACAddress,SerialNumber,Extension,LineLabel");
        foreach (var p in phones)
            sb.AppendLine($"{Csv(p.Brand)},{Csv(p.PhoneModel)},{Csv(p.MACAddress)},{Csv(p.SerialNumber)},{Csv(p.Extension)},{Csv(p.LineLabel)}");
        return sb.ToString();

        static string Csv(string v) =>
            v.Contains(',') || v.Contains('"') || v.Contains('\n')
                ? $"\"{v.Replace("\"", "\"\"")}\"" : v;
    }

    // ── UI helpers ─────────────────────────────────────────────────
    private void AddResult(string category, string detail, string status)
    {
        Dispatcher.Invoke(() =>
        {
            Results.Add(new CheckResult { Category = category, Detail = detail, Status = status });
            _reportLines.Add($"[{status,-4}] {category}  -  {detail}");
        });
    }

    private void AddSection(string title)
    {
        Dispatcher.Invoke(() =>
        {
            Results.Add(new CheckResult { IsSection = true, SectionTitle = title });
            _reportLines.Add($"\n{title}");
            _reportLines.Add(new string('-', 60));
        });
    }

    private void SetStatus(string text, double progress = -1)
    {
        Dispatcher.Invoke(() =>
        {
            lblStatus.Text = text;
            if (progress >= 0)
            {
                progressBar.IsIndeterminate = false;
                progressBar.Value = progress;
            }
        });
    }
}
