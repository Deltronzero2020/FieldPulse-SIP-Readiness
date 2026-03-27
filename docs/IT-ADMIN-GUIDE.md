# IT Administrator Guide — FieldPulse SIP Readiness Check

This guide covers firewall rules, antivirus considerations, and deployment instructions for IT administrators.

---

## What This Tool Does

The FieldPulse SIP Readiness Check verifies that a customer's network can support SIP phone registration. It tests:

- TCP connectivity to FieldPulse SIP/HTTP endpoints
- Network latency and jitter (ICMP ping)
- Router/gateway configuration
- Local device discovery (ARP table)

---

## Network Requirements

### Outbound Connections Required

| Destination | Ports | Protocol | Purpose |
|-------------|-------|----------|---------|
| 75.98.50.201, 207.254.80.55, 207.254.80.59, 207.254.80.76, 76.164.212.85 | 80, 443 | TCP | FieldPulse HTTP endpoints |
| 54.172.60.0–3, 54.244.51.0–3 | 5060, 5061 | TCP | FieldPulse SIP servers |
| 168.86.128.0/18 | 10000–20000 | UDP | RTP media (not tested by this tool) |
| script.google.com | 443 | TCP | Report submission webhook |
| api.ipify.org | 443 | TCP | Public IP detection |

### ICMP (Ping)

- Outbound ICMP echo requests to gateway and FieldPulse SIP IPs
- Used for latency/jitter measurement
- If blocked, the tool reports "Inconclusive" (not a failure)

---

## Firewall Configuration

### Windows Defender Firewall

No changes needed — outbound connections are allowed by default.

### Enterprise Firewalls (Palo Alto, Fortinet, etc.)

Create an outbound allow rule:

```
Source:      Internal network / workstation IP
Destination: 75.98.50.201, 207.254.80.55, 207.254.80.59, 207.254.80.76, 76.164.212.85,
             54.172.60.0/30, 54.244.51.0/30
Ports:       TCP 80, 443, 5060, 5061
Action:      Allow
```

Optional (for latency tests):
```
Protocol:    ICMP
Type:        Echo Request (Type 8)
Action:      Allow
```

---

## Antivirus Considerations

### Why It Might Be Flagged

| Behavior | Reason | Risk Level |
|----------|--------|------------|
| TCP connections to multiple IPs/ports | Resembles port scanning | Low — only connects to known FieldPulse IPs |
| Unsigned executable | SmartScreen warning | None — can be code-signed to eliminate |
| Self-contained .NET app | Large EXE with bundled runtime | None — standard Microsoft .NET deployment |
| ICMP ping | Network probing | None — standard diagnostic behavior |

### Recommended Exclusions

If your antivirus flags the application, add an exclusion for:

```
Path: C:\Path\To\FieldPulse-SIP-Readiness\FieldPulse-SIP-Readiness.exe
```

Or exclude by hash (SHA256) — contact FieldPulse for the signed release hash.

### SmartScreen Warning

On first run, Windows SmartScreen may show "Windows protected your PC." This is normal for new/unsigned applications.

**To proceed:**
1. Click "More info"
2. Click "Run anyway"

To eliminate this warning, deploy the code-signed version of the EXE.

---

## Deployment Options

### Option 1: Single EXE (Recommended)

Deploy the self-contained EXE to any Windows 10/11 x64 machine. No installation required.

```
FieldPulse-SIP-Readiness/
  FieldPulse-SIP-Readiness.exe    <- Run this
  README.txt                       <- Quick start instructions
```

### Option 2: Network Share

Place the deployment folder on a network share. Users run the EXE directly — no local installation needed.

```
\\server\share\FieldPulse-SIP-Readiness\FieldPulse-SIP-Readiness.exe
```

### Option 3: Software Distribution (SCCM, Intune, etc.)

Package the deployment folder as a Win32 app. No silent install needed — it's a portable executable.

---

## System Requirements

- Windows 10 or Windows 11 (x64)
- .NET not required (bundled in EXE)
- Administrator rights not required
- Internet access required for report submission

---

## Data Privacy

### What Data Is Collected

- Customer name (entered by user)
- Computer name
- Local/public IP addresses
- Network test results (pass/warn/fail counts)
- Phone inventory (if provided)
- Onboarding preferences

### Where Data Is Sent

Reports are submitted via HTTPS to a FieldPulse-controlled Google Apps Script webhook. Data is:

- Transmitted over TLS 1.2+
- Authenticated with HMAC-SHA256 signature
- Stored in FieldPulse's Google Drive
- Emailed to the FieldPulse onboarding team

No data is sent to third parties. No telemetry or analytics are collected.

---

## Troubleshooting

### "Connection timed out" errors

- Check firewall rules for outbound TCP to FieldPulse IPs
- Verify proxy settings (tool does not use system proxy)

### Latency tests show "Inconclusive"

- ICMP may be blocked by firewall
- This is informational only — not a blocker

### Report submission fails

- Verify outbound HTTPS to script.google.com is allowed
- Check for SSL inspection that may interfere with certificate validation

### SmartScreen blocks the EXE

- Click "More info" → "Run anyway"
- Or deploy the code-signed version

---

## Support

For questions about this tool, contact your FieldPulse representative or email support@fieldpulse.com.
