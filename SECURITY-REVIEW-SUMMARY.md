# FieldPulse SIP Readiness - Security & Quality Review

**Review Date:** 2026-03-27
**Reviewer:** Claude Code (Opus 4.5)
**Project:** FieldPulse SIP Phone Registration Readiness Check Tool

---

## Executive Summary

This document summarizes a comprehensive security and quality review of the FieldPulse SIP Readiness diagnostic tool. The tool helps customers verify their network is ready for SIP phone onboarding by testing connectivity, latency, router configuration, and device discovery.

**Components Reviewed:**
- `FieldPulse-SIP-Readiness.ps1` - PowerShell GUI application (main script)
- `FieldPulse-SIP-Readiness-Backend.gs` - Google Apps Script webhook receiver
- `WPF/` - .NET 9 WPF desktop application
- `Sign-Script.ps1` - Code signing utility
- `FieldPulse-SIP-Readiness.bat` - Windows batch launcher

---

## Findings by Severity

### Critical (Fixed)

| Issue | Location | Fix Applied |
|-------|----------|-------------|
| HTTP timestamp server (MITM risk) | Sign-Script.ps1:146 | Changed to HTTPS |
| HMAC timing attack vulnerability | Backend.gs:65-70 | Constant-time comparison with padding |
| CSV base64 size bypass | Backend.gs:273-275 | Added decoded size validation (2MB limit) |

### High (Fixed)

| Issue | Location | Fix Applied |
|-------|----------|-------------|
| TCP resources not disposed | PS1:383-417 | Added try/finally with Dispose() |
| Email failure not reported | Backend.gs:294-297 | Returns `status: 'partial'` with message |
| Non-fatal signing errors | Sign-Script.ps1:148-151 | Now exits with code 1 on failure |
| Silent catch blocks | WPF/MainWindow.xaml.cs | Added structured exception logging |
| Form fields lack newline validation | PS1:1470-1483 | Added CRLF injection check |

### Medium (Fixed)

| Issue | Location | Fix Applied |
|-------|----------|-------------|
| Weak email validation regex | PS1, WPF | Upgraded to RFC 5322 compliant regex |
| No request deduplication | Backend.gs | Added 5-minute dedup window with MD5 key |
| Magic numbers scattered | All files | Extracted to named constants |
| No accessibility attributes | WPF XAML | Added AutomationProperties |
| BAT file no pause on success | .bat | Added success message and pause |

---

## Changes by Phase

### Phase 1: Security (Critical)

**Sign-Script.ps1:**
```diff
- -TimestampServer 'http://timestamp.digicert.com'
+ -TimestampServer 'https://timestamp.digicert.com'
```

**Backend.gs - HMAC Timing Fix:**
```javascript
// Before: Early return on length mismatch (timing leak)
if (expected.length !== clientSig.length) return false;

// After: Constant-time comparison with padding
var maxLen = Math.max(expected.length, clientSig.length);
var mismatch = expected.length ^ clientSig.length;
for (var i = 0; i < maxLen; i++) {
  var expectedChar = i < expected.length ? expected.charCodeAt(i) : 0;
  var clientChar   = i < clientSig.length ? clientSig.charCodeAt(i) : 0;
  mismatch |= expectedChar ^ clientChar;
}
return mismatch === 0;
```

**PS1 - Newline Validation:**
```powershell
# Added validation for CRLF injection in form fields
$fieldsToCheck = @(
    @{ Name = 'Phone count';    Value = $txtPhoneCount.Text },
    @{ Name = 'Phone models';   Value = $txtModels.Text },
    # ... etc
)
foreach ($field in $fieldsToCheck) {
    if ($field.Value -match '[\r\n]') {
        $valErrors.Add("$($field.Name) contains invalid line breaks.")
    }
}
```

### Phase 2: Reliability

**Backend.gs - Partial Status Response:**
```javascript
if (emailSent) {
  return jsonResponse({ status: 'ok', drive_url: driveUrl });
} else {
  return jsonResponse({
    status: 'partial',
    message: 'Report saved to Drive but email notification failed.',
    drive_url: driveUrl
  });
}
```

**WPF/App.xaml.cs - Structured Logging:**
```csharp
public static void WriteStructuredLog(string severity, string source,
    Exception? ex, string? additionalContext = null)
{
    var entry = $"""
        Timestamp : {DateTime.UtcNow:O}
        Severity  : {severity}
        Source    : {source}
        Machine   : {Environment.MachineName}
        Exception : {ex?.GetType().FullName}
        Message   : {ex?.Message}
        Stack Trace: {ex?.ToString()}
        """;
    File.AppendAllText(LogPath, entry);
}
```

**PS1 - TCP Resource Disposal:**
```powershell
foreach ($p in $allProbes) {
    try {
        if ($p.AR) { $ok = $p.AR.AsyncWaitHandle.WaitOne(0, $false) }
        $script:tcpCache["$($p.IP):$($p.Port)"] = $ok
    }
    finally {
        if ($p.AR.AsyncWaitHandle) { $p.AR.AsyncWaitHandle.Close() }
        if ($p.Client) { $p.Client.Close(); $p.Client.Dispose() }
    }
}
```

### Phase 3: Quality

**Request Deduplication (Backend.gs):**
```javascript
var DEDUP_WINDOW_MINS = 5;

function checkDuplicateSubmission(customer, date, passCount, failCount, warnCount, computer) {
  var rawKey = [customer, date, passCount, failCount, warnCount, computer].join('|');
  var keyHash = Utilities.base64Encode(
    Utilities.computeDigest(Utilities.DigestAlgorithm.MD5, rawKey)
  );
  // Check if exists within window, return isDuplicate: true/false
}
```

**Configuration Constants (PS1):**
```powershell
$TCP_PROBE_TIMEOUT_MS   = 1500
$HTTP_REQUEST_TIMEOUT_S = 20
$MAX_LATENCY_GOOD_MS    = 100
$MAX_LATENCY_WARN_MS    = 150
$MAX_JITTER_GOOD_MS     = 20
$MAX_JITTER_WARN_MS     = 30
```

**Accessibility Attributes (WPF):**
```xml
<Button x:Name="btnRun"
        Content="Run Checks"
        AutomationProperties.Name="Run network checks"
        AutomationProperties.HelpText="Execute all network diagnostics"/>
```

---

## Files Modified

| File | Changes |
|------|---------|
| `Sign-Script.ps1` | HTTPS timestamp, fatal errors, exit code |
| `FieldPulse-SIP-Readiness-Backend.gs` | HMAC fix, CSV validation, constants, dedup, partial status |
| `FieldPulse-SIP-Readiness.ps1` | TCP disposal, newline validation, constants, status handling |
| `WPF/App.xaml.cs` | Structured logging, audit logging, task exception handler |
| `WPF/MainWindow.xaml.cs` | Constants, partial/duplicate handling, audit logging |
| `WPF/MainWindow.xaml` | Accessibility attributes |
| `WPF/SubmissionDialog.xaml.cs` | Email regex |
| `WPF/SubmissionDialog.xaml` | Accessibility attributes |
| `FieldPulse-SIP-Readiness.bat` | Success message, proper exit code |

---

## Recommendations for Future Work

### Not Addressed in This Review

1. **Externalize secrets to secure storage**
   - Move `WEBHOOK_SECRET` to Windows Credential Manager (PS1/WPF)
   - Move to Google Script Properties (Backend.gs)

2. **Add unit tests**
   - Test `sanitizeIP()`, `sanitizeDate()`, `htmlEscape()` edge cases
   - Test HMAC verification with malformed inputs

3. **Improve accessibility further**
   - Add high-contrast mode support
   - Add keyboard shortcuts (AccessKey)
   - Test with screen readers

4. **Add metrics/monitoring**
   - Track daily submissions by status
   - Alert on error rate spikes

---

## Security Posture Assessment

| Category | Before | After |
|----------|--------|-------|
| Authentication | HMAC-SHA256 (timing vulnerable) | HMAC-SHA256 (constant-time) |
| Input Validation | Partial | Comprehensive (CSV, forms, CRLF) |
| Resource Management | Leaky | Proper disposal |
| Error Handling | Silent failures | Structured logging + user feedback |
| Deduplication | None | 5-minute window |
| Accessibility | None | WCAG-compatible attributes |

**Overall Assessment:** Suitable for internal customer onboarding tool with current fixes applied.

---

## Appendix: Test Checklist

- [ ] Run `Sign-Script.ps1 -SelfSigned` and verify HTTPS timestamp
- [ ] Submit duplicate report within 5 minutes - should return "duplicate"
- [ ] Submit report, kill email service - should return "partial"
- [ ] Enter newlines in form fields - should show validation error
- [ ] Upload CSV > 2MB - should be rejected
- [ ] Test with screen reader (Narrator/NVDA)
- [ ] Verify error.log contains structured entries after forced error

---

*Generated by Claude Code security review - 2026-03-27*
