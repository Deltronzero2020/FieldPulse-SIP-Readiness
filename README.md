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
| `FieldPulse-SIP-Readiness.ps1` | PowerShell GUI application (WinForms) |
| `WPF/` | .NET 9 WPF desktop application (alternative) |
| `FieldPulse-SIP-Readiness-Backend.gs` | Google Apps Script webhook receiver |
| `Sign-Script.ps1` | Code signing utility for EXE distribution |
| `FieldPulse-SIP-Readiness.bat` | Windows batch launcher |

## Quick Start

### Option 1: PowerShell Script
```powershell
# Right-click > Run with PowerShell (as Administrator)
.\FieldPulse-SIP-Readiness.ps1
```

### Option 2: Batch Launcher
```cmd
# Double-click or run from command prompt
FieldPulse-SIP-Readiness.bat
```

### Option 3: WPF Application
```powershell
cd WPF
dotnet run
```

## Building

### PowerShell to EXE (Signed)
```powershell
# Self-signed certificate (free, SmartScreen warning)
.\Sign-Script.ps1 -SelfSigned

# Commercial certificate (no warning)
.\Sign-Script.ps1 -Thumbprint "YOUR_CERT_THUMBPRINT"
```

### WPF Application
```powershell
cd WPF
dotnet build -c Release
dotnet publish -c Release -r win-x64 --self-contained
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

## Security

- HMAC-SHA256 request signing
- TLS 1.2 enforced for all HTTPS
- CSV injection validation
- CRLF injection prevention
- Request deduplication (5-minute window)
- Constant-time HMAC comparison

See [SECURITY-REVIEW-SUMMARY.md](SECURITY-REVIEW-SUMMARY.md) for full security audit.

## License

Internal use only - FieldPulse proprietary.
