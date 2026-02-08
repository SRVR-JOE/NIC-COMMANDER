@echo off
title NIC Command Center v2.0
color 0B
echo.
echo  ============================================
echo    NIC COMMAND CENTER v2.0
echo    Network Configurator + Diagnostics
echo  ============================================
echo.
echo  Launching PowerShell backend as Administrator...
echo.

powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process powershell -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File \"%~dp0NIC-CommandCenter.ps1\"' -Verb RunAs"

echo  Server starting on http://localhost:8977
echo  Close this window when server is running.
timeout /t 5
