<#
.SYNOPSIS
    Builds a clean deployment folder for FieldPulse SIP Readiness Check.

.DESCRIPTION
    Compiles the WPF application and creates a deployment-ready folder
    containing only the files needed for customer distribution.
    Run from any directory — the script resolves the repo root automatically.

.PARAMETER OutputPath
    Path where the deployment folder will be created (relative to repo root).
    Default: .\Deploy

.PARAMETER SignCert
    Optional certificate thumbprint for code signing.

.EXAMPLE
    .\scripts\Build-Deployment.ps1
    # Creates .\Deploy folder with unsigned EXE

.EXAMPLE
    .\scripts\Build-Deployment.ps1 -SignCert "ABC123..."
    # Creates signed deployment
#>

param(
    [string]$OutputPath = ".\Deploy",
    [string]$SignCert = ""
)

$ErrorActionPreference = "Stop"

# Resolve repo root (one level up from scripts/)
$RepoRoot = Split-Path -Parent $PSScriptRoot

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  FieldPulse SIP Readiness - Build" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# Step 1: Clean output folder
$OutputFull = Join-Path $RepoRoot $OutputPath
if (Test-Path $OutputFull) {
    Write-Host "[1/6] Cleaning existing deployment folder..." -ForegroundColor Yellow
    Remove-Item -Path $OutputFull -Recurse -Force
}
New-Item -Path $OutputFull -ItemType Directory -Force | Out-Null
Write-Host "[1/6] Created deployment folder: $OutputFull" -ForegroundColor Green

# Step 2: Build the WPF application
Write-Host "[2/6] Building WPF application (Release, self-contained)..." -ForegroundColor Yellow
Push-Location (Join-Path $RepoRoot "src")
try {
    dotnet publish -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -p:IncludeNativeLibrariesForSelfExtract=true -o $OutputFull 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "dotnet publish failed with exit code $LASTEXITCODE"
    }
    Write-Host "[2/6] Build completed successfully." -ForegroundColor Green
} finally {
    Pop-Location
}

# Step 3: Code sign (optional)
$exePath = Join-Path $OutputFull "FieldPulse-SIP-Readiness.exe"
if ($SignCert) {
    Write-Host "[3/6] Signing executable with certificate $SignCert..." -ForegroundColor Yellow
    try {
        $cert = Get-ChildItem -Path Cert:\CurrentUser\My -CodeSigningCert | Where-Object { $_.Thumbprint -eq $SignCert }
        if (-not $cert) {
            $cert = Get-ChildItem -Path Cert:\LocalMachine\My -CodeSigningCert | Where-Object { $_.Thumbprint -eq $SignCert }
        }
        if (-not $cert) {
            throw "Certificate with thumbprint $SignCert not found."
        }
        Set-AuthenticodeSignature -FilePath $exePath -Certificate $cert -TimestampServer "http://timestamp.digicert.com" | Out-Null
        Write-Host "[3/6] Code signing completed." -ForegroundColor Green
    } catch {
        Write-Host "[3/6] Code signing failed: $_" -ForegroundColor Red
        Write-Host "       Continuing with unsigned EXE." -ForegroundColor Yellow
    }
} else {
    Write-Host "[3/6] Skipping code signing (no certificate provided)." -ForegroundColor Gray
}

# Step 4: Create README.txt
Write-Host "[4/6] Creating README.txt..." -ForegroundColor Yellow
$readmeContent = @"
================================================================================
  FIELDPULSE SIP READINESS CHECK
  Quick Start Guide
================================================================================

WHAT THIS TOOL DOES
-------------------
Tests your network's readiness for SIP phone registration with FieldPulse Engage.
It checks connectivity, latency, and collects information for onboarding.


HOW TO RUN
----------
1. Double-click "FieldPulse-SIP-Readiness.exe"
2. If SmartScreen appears, click "More info" then "Run anyway"
3. Enter your company name
4. Click "Run Checks"
5. Review results, then click "Send to FieldPulse"
6. Fill in the onboarding form and submit


RESULTS EXPLAINED
-----------------
[PASS]  - Test passed, no action needed
[WARN]  - May need attention, review details
[FAIL]  - Action required before SIP phones will work


COMMON ISSUES
-------------
- "Connection timed out" = Firewall may be blocking outbound connections
- "Latency inconclusive" = ICMP ping is blocked (usually OK)
- SmartScreen warning = Normal for new apps, click through to run


NEED HELP?
----------
Contact your FieldPulse representative or email support@fieldpulse.com

For IT administrators, see IT-ADMIN-GUIDE.md for firewall and AV details.

================================================================================
"@
$readmeContent | Out-File -FilePath (Join-Path $OutputFull "README.txt") -Encoding UTF8
Write-Host "[4/6] README.txt created." -ForegroundColor Green

# Step 5: Copy documentation
Write-Host "[5/6] Copying User Guide..." -ForegroundColor Yellow
Copy-Item -Path (Join-Path $RepoRoot "docs\USER-GUIDE.md") -Destination (Join-Path $OutputFull "USER-GUIDE.md") -Force
Write-Host "[5/6] USER-GUIDE.md copied." -ForegroundColor Green

Write-Host "[6/6] Copying IT Admin Guide..." -ForegroundColor Yellow
Copy-Item -Path (Join-Path $RepoRoot "docs\IT-ADMIN-GUIDE.md") -Destination $OutputFull -Force
Write-Host "[6/6] IT-ADMIN-GUIDE.md copied." -ForegroundColor Green

# Summary
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "  BUILD COMPLETE" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "`nDeployment folder: $((Resolve-Path $OutputFull).Path)" -ForegroundColor White
Write-Host "`nContents:" -ForegroundColor White
Get-ChildItem -Path $OutputFull | ForEach-Object {
    $size = if ($_.Length -gt 1MB) { "{0:N1} MB" -f ($_.Length / 1MB) } else { "{0:N0} KB" -f ($_.Length / 1KB) }
    Write-Host ("  {0,-40} {1,10}" -f $_.Name, $size)
}

Write-Host "`nNext steps:" -ForegroundColor Yellow
Write-Host "  1. Test the EXE on a Windows machine"
Write-Host "  2. Zip the Deploy folder for distribution"
Write-Host "  3. Share with customers or deploy via network share`n"
