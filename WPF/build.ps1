#Requires -Version 5.1
<#
.SYNOPSIS
    Build script for FieldPulse SIP Readiness WPF tool.
.DESCRIPTION
    Publishes a self-contained single-file Windows exe using dotnet.
    Run from the WPF folder on the Windows VM.
.EXAMPLE
    .\build.ps1
    .\build.ps1 -Configuration Debug
    .\build.ps1 -Sign
#>

param(
    [ValidateSet("Release","Debug")]
    [string]$Configuration = "Release",

    [switch]$Sign,

    # Pass -SelfContained to bundle the .NET runtime (requires nuget.org access).
    # Default: framework-dependent (smaller exe, requires .NET 9 Desktop Runtime on target).
    [switch]$SelfContained
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ProjectFile = Join-Path $PSScriptRoot "FieldPulse-SIP-Readiness.csproj"
$OutDir      = Join-Path $PSScriptRoot "publish"

Write-Host ""
Write-Host "================================================" -ForegroundColor Cyan
Write-Host "  FieldPulse SIP Readiness - Build Script" -ForegroundColor Cyan
Write-Host "================================================" -ForegroundColor Cyan
Write-Host "  Configuration : $Configuration"
Write-Host "  Output dir    : $OutDir"
Write-Host ""

# --- 1. Verify prerequisites ---
if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
    Write-Error "dotnet SDK not found. Download from https://dot.net"
}

$sdkVersion = (dotnet --version 2>&1)
Write-Host "  .NET SDK : $sdkVersion" -ForegroundColor Gray
Write-Host ""

# --- 2. Verify NuGet connectivity (needed for self-contained runtime packs) ---
if ($SelfContained) {
    Write-Host "Checking NuGet connectivity..." -ForegroundColor Gray
    try {
        $null = Invoke-WebRequest "https://api.nuget.org/v3/index.json" -UseBasicParsing -TimeoutSec 10
        Write-Host "  nuget.org : reachable" -ForegroundColor Green
    } catch {
        Write-Host "  nuget.org : NOT reachable" -ForegroundColor Red
        Write-Host ""
        Write-Host "Self-contained publish needs to download runtime packs from nuget.org." -ForegroundColor Yellow
        Write-Host "Check VM network settings or run without -SelfContained to skip this." -ForegroundColor Yellow
        exit 1
    }
    Write-Host ""
}

# --- 3. Clean previous output ---
if (Test-Path $OutDir) {
    Write-Host "Cleaning previous publish output..." -ForegroundColor Yellow
    Remove-Item $OutDir -Recurse -Force
}

# --- 3. Publish ---
if ($SelfContained) {
    Write-Host "Publishing self-contained single-file win-x64..." -ForegroundColor Cyan
} else {
    Write-Host "Publishing framework-dependent single-file win-x64..." -ForegroundColor Cyan
    Write-Host "  NOTE: Requires .NET 9 Desktop Runtime on target machine." -ForegroundColor Yellow
}

$publishArgs = @(
    "publish"
    $ProjectFile
    "--configuration",   $Configuration
    "--runtime",         "win-x64"
    "--output",          $OutDir
    "-p:PublishSingleFile=true"
    "-p:DebugType=embedded"
    "--nologo"
)

if ($SelfContained) {
    $publishArgs += "--self-contained"
    $publishArgs += "true"
    $publishArgs += "-p:IncludeNativeLibrariesForSelfExtract=true"
    $publishArgs += "-p:EnableCompressionInSingleFile=true"
} else {
    $publishArgs += "--self-contained"
    $publishArgs += "false"
}

& dotnet @publishArgs

if ($LASTEXITCODE -ne 0) {
    Write-Error "dotnet publish failed with exit code $LASTEXITCODE."
}

# --- 4. Locate output exe ---
$exePath = Join-Path $OutDir "FieldPulse-SIP-Readiness.exe"
if (-not (Test-Path $exePath)) {
    Write-Error "Expected output not found: $exePath"
}

$sizeMB = [math]::Round((Get-Item $exePath).Length / 1MB, 1)
Write-Host ""
Write-Host "Build succeeded!" -ForegroundColor Green
Write-Host "  Output : $exePath"
Write-Host "  Size   : ${sizeMB} MB"

# --- 5. Optional Authenticode signing ---
if ($Sign) {
    Write-Host ""
    Write-Host "Signing the executable..." -ForegroundColor Cyan

    $cert = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert |
            Where-Object { $_.Subject -like "*FieldPulse*" } |
            Select-Object -First 1

    if (-not $cert) {
        $cert = Get-ChildItem Cert:\CurrentUser\My -CodeSigningCert |
                Select-Object -First 1
    }

    if (-not $cert) {
        Write-Warning "No code-signing certificate found in CurrentUser\My. Skipping signing."
        Write-Warning "Install your .pfx first: certutil -user -p PASSWORD -importpfx cert.pfx"
    }
    else {
        Write-Host "  Certificate: $($cert.Subject)" -ForegroundColor Gray
        Set-AuthenticodeSignature -FilePath $exePath -Certificate $cert `
            -TimestampServer "http://timestamp.digicert.com" | Out-Null

        $sig = Get-AuthenticodeSignature $exePath
        if ($sig.Status -eq "Valid") {
            Write-Host "  Signed OK" -ForegroundColor Green
        } else {
            Write-Warning "Signing status: $($sig.Status)"
        }
    }
}

Write-Host ""
Write-Host "Done." -ForegroundColor Green
Write-Host ""
