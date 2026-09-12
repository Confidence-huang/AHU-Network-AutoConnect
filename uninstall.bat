@echo off
rem Bootstraps the PowerShell uninstaller.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1" %*
pause
