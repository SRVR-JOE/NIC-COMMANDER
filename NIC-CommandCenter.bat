@echo off
title NIC Command Center v2.1
color 0B
echo.
echo  ============================================
echo    NIC COMMAND CENTER v2.1
echo    Network Configurator + Diagnostics
echo  ============================================
echo.
echo  Launching PowerShell backend as Administrator...
echo.

powershell -NoProfile -ExecutionPolicy Bypass -Command "try { Start-Process powershell -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File \"%~dp0NIC-CommandCenter.ps1\"' -Verb RunAs -ErrorAction Stop } catch { Write-Host 'ERROR: Administrator privileges required.' -ForegroundColor Red; exit 1 }"

if %ERRORLEVEL% neq 0 (
    echo.
    echo  ERROR: Failed to launch. Administrator privileges required.
    pause
    exit /b 1
)

echo  Server starting on http://127.0.0.1:8977
echo  This window can be closed.
timeout /t 5
