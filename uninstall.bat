@echo off
rem Bootstraps the PowerShell uninstaller.
rem Prefer PowerShell 7 (pwsh); fall back to 5.1 only when pwsh is absent.
where pwsh.exe >nul 2>&1 && (set "PS=pwsh") || (set "PS=powershell")
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0uninstall.ps1" %*
pause
