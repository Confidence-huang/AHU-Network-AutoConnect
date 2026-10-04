@echo off
rem Bootstraps the PowerShell installer. All real logic lives in install.ps1;
rem complex logic in batch files breaks easily across Windows code pages.
rem Prefer PowerShell 7 (pwsh); fall back to 5.1 only when pwsh is absent.
where pwsh.exe >nul 2>&1 && (set "PS=pwsh") || (set "PS=powershell")
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
pause
