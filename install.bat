@echo off
rem Bootstraps the PowerShell installer. All real logic lives in install.ps1;
rem complex logic in batch files breaks easily across Windows code pages.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
pause
