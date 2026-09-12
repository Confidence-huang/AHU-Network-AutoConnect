# AHU campus network auto connect - uninstaller.
# Removes the logon Run key and both scheduled tasks. The deployed folder is
# kept unless -Purge is passed (it contains your credential config and logs).
[CmdletBinding()]
param(
    [string]$HomeDirectory = "$env:APPDATA\ahu-network",
    [switch]$Purge
)

$ErrorActionPreference = "SilentlyContinue"

foreach ($taskName in @("AHU-Network-AutoConnect", "AHU-Network-AutoConnect-OnNetwork")) {
    if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
        Write-Host "[uninstall] Removed scheduled task $taskName"
    }
}

$runKeyPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$runValue   = Get-ItemProperty -LiteralPath $runKeyPath -Name "AHU-Network-AutoConnect" -ErrorAction SilentlyContinue
if ($runValue) {
    Remove-ItemProperty -LiteralPath $runKeyPath -Name "AHU-Network-AutoConnect"
    Write-Host "[uninstall] Removed logon Run key"
}

if ($Purge) {
    Remove-Item -LiteralPath $HomeDirectory -Recurse -Force
    Write-Host "[uninstall] Deleted $HomeDirectory including config.json and logs"
}
else {
    Write-Host "[uninstall] Kept $HomeDirectory (config.json still contains credentials; delete manually or pass -Purge)"
}

Write-Host "[uninstall] Done."
