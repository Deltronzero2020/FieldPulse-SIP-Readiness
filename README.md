# FieldPulse SIP Readiness Check

A Windows diagnostic tool for verifying network readiness before SIP phone onboarding with FieldPulse Engage.

## Features

- **Network Connectivity Testing** - Validates TCP connectivity to FieldPulse HTTP, SIP, and RTP endpoints
- **Latency & Jitter Analysis** - ICMP ping tests with VoIP quality thresholds
- **Router Detection** - Identifies router brand and provides SIP ALG disable instructions
- **Device Discovery** - Scans ARP table for SIP phones by MAC address OUI
- **Secure Submission** - HMAC-SHA256 signed reports sent via HTTPS to Google Apps Script backend
- **Onboarding Data Collection** - Phone inventory, attendee contacts, and customer confirmations

## Components

| Component | Description |
|-----------|-------------|
| `WPF/` | .NET 9 WPF desktop application (recommended) |
| `FieldPulse-SIP-Readiness.ps1` | PowerShell GUI application (alternative) |
| `FieldPulse-SIP-Readiness-Backend.gs` | Google Apps Script webhook receiver |
| `Build-Deployment.ps1` | Creates clean deployment folder |
| `IT-ADMIN-GUIDE.md` | Firewall/AV guide for IT administrators |
| `Sign-Script.ps1` | Code signing utility |

## Customer Deployment

### Build a Clean Deployment Folder

```powershell
# Run from the repo root (on Windows with .NET SDK installed)
.\Build-Deployment.ps1

# With code signing (eliminates SmartScreen warning)
.\Build-Deployment.ps1 -SignCert "YOUR_CERT_THUMBPRINT"
```

This creates a `Deploy/` folder containing:

```
Deploy/
  FieldPulse-SIP-Readiness.exe   <- Single-file EXE (no install needed)
  README.txt                      <- Quick start for end users
  IT-ADMIN-GUIDE.md               <- Firewall/AV guide for IT teams
```

### Distribute to Customers

1. **Zip the Deploy folder** and send to customers
2. **Or** place on a network share for direct access
3. **Or** deploy via SCCM/Intune as a portable app

### End User Instructions

1. Extract the zip (or run from network share)
2. Double-click `FieldPulse-SIP-Readiness.exe`
3. If SmartScreen appears: click "More info" → "Run anyway"
4. Enter company name → Click "Run Checks"
5. Review results → Click "Send to FieldPulse"

---

## Development

### Quick Start (Development)

```powershell
# Run the WPF app directly
cd WPF
dotnet run

# Or run the PowerShell version
.\FieldPulse-SIP-Readiness.ps1
```

### Build Commands

```powershell
# WPF - Debug build
cd WPF
dotnet build

# WPF - Release build (single-file EXE)
dotnet publish -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true
```

## Backend Setup

1. Go to [script.google.com](https://script.google.com) > New project
2. Paste contents of `FieldPulse-SIP-Readiness-Backend.gs`
3. Configure `NOTIFY_EMAIL`, `DRIVE_FOLDER_ID`, `WEBHOOK_SECRET`
4. Deploy > New deployment > Web app
5. Copy Web app URL to client configuration

## Configuration

### Client (PS1/WPF)
```powershell
$WEBHOOK_URL    = "https://script.google.com/macros/s/YOUR_DEPLOYMENT_ID/exec"
$WEBHOOK_SECRET = "your-shared-secret-uuid"
```

### Backend (Apps Script)
```javascript
var NOTIFY_EMAIL    = 'team@yourcompany.com';
var DRIVE_FOLDER_ID = 'your-drive-folder-id';
var WEBHOOK_SECRET  = 'your-shared-secret-uuid';
```

## Network Requirements

The tool tests connectivity to:

| Service | IPs | Ports |
|---------|-----|-------|
| HTTP | 75.98.50.201, 207.254.80.55, etc. | 80, 443 |
| SIP | 54.172.60.0-3, 54.244.51.0-3 | 5060, 5061 |
| RTP | 168.86.128.0/18 | 10000-20000 (UDP) |

## IT Administrator Notes

For enterprise deployments, see **[IT-ADMIN-GUIDE.md](IT-ADMIN-GUIDE.md)** which covers:

- Firewall rules for FieldPulse IPs
- Antivirus exclusion recommendations
- SmartScreen and code signing
- Data privacy and what's collected

### Quick Firewall Summary

| Destination | Ports | Protocol |
|-------------|-------|----------|
| FieldPulse HTTP IPs | 80, 443 | TCP |
| FieldPulse SIP IPs | 5060, 5061 | TCP |
| script.google.com | 443 | TCP |
| ICMP (optional) | - | ICMP Echo |

---

## Security

- HMAC-SHA256 request signing
- TLS 1.2 enforced for all HTTPS
- CSV injection validation
- CRLF injection prevention
- Request deduplication (5-minute window)
- Constant-time HMAC comparison

See [SECURITY-REVIEW-SUMMARY.md](SECURITY-REVIEW-SUMMARY.md) for full security audit.

---

## License

Internal use only - FieldPulse proprietary.
