@echo off
rem Fallback launcher. A console window may flash briefly.
rem Prefer MousePowerTray.vbs for a fully silent start.
start "" powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0src\MousePowerTray.ps1"
