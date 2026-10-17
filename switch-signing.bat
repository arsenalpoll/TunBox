@echo off
rem Double-click launcher for switch-signing.ps1 (interactive mode menu)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0switch-signing.ps1" %*
pause
