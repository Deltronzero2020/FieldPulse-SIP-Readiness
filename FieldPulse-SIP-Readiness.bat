@echo off
title FieldPulse SIP Readiness Check
echo.
echo  FieldPulse Engage - SIP Phone Registration Readiness Check
echo  -----------------------------------------------------------
echo.

REM Check if the PowerShell script is in the same folder as this .bat
if not exist "%~dp0FieldPulse-SIP-Readiness.ps1" (
    echo  ERROR: FieldPulse-SIP-Readiness.ps1 not found.
    echo  Make sure both files are in the same folder.
    echo.
    pause
    exit /b 1
)

REM Run the PowerShell script with execution policy bypass scoped to this invocation only.
REM -ExecutionPolicy Bypass does NOT change the machine policy permanently.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0FieldPulse-SIP-Readiness.ps1"

if %ERRORLEVEL% NEQ 0 (
    echo.
    echo  -------------------------------------------------------
    echo  Script exited with error code: %ERRORLEVEL%
    echo  -------------------------------------------------------
    echo.
    echo  To see the full error message, open PowerShell manually and run:
    echo.
    echo    powershell -ExecutionPolicy Bypass -File "%~dp0FieldPulse-SIP-Readiness.ps1"
    echo.
) else (
    echo.
    echo  -------------------------------------------------------
    echo  SIP Readiness Check completed successfully.
    echo  -------------------------------------------------------
    echo.
)
pause
exit /b %ERRORLEVEL%
