# AHU campus network auto connect - installer.
# Deploys the engine to %APPDATA%\ahu-network and registers three user-level
# entry points: a logon Run key, an hourly scheduled task, and a task bound to
# the Windows NetworkProfile connect event (Event ID 10000).
#
# Existing files are backed up before being replaced; an existing config.json
# is never touched. Run with: powershell -ExecutionPolicy Bypass -File install.ps1
[CmdletBinding()]
param(
    [string]$HomeDirectory = "$env:APPDATA\ahu-network",
    [switch]$SkipScheduledTasks,
    [switch]$SkipVerification
)

$ErrorActionPreference = "Stop"
$scriptRoot = $PSScriptRoot

function Write-Step {
    param([string]$Message)
    Write-Host "[install] $Message"
}

function Backup-Existing {
    param(
        [string]$Path,
        [string]$BackupDirectory
    )

    if (Test-Path -LiteralPath $Path) {
        if (-not (Test-Path -LiteralPath $BackupDirectory)) {
            New-Item -ItemType Directory -Path $BackupDirectory -Force | Out-Null
        }
        Copy-Item -LiteralPath $Path -Destination (Join-Path $BackupDirectory (Split-Path $Path -Leaf)) -Force
        Write-Step "Backed up $(Split-Path $Path -Leaf)"
    }
}

if (-not (Test-Path -LiteralPath (Join-Path $scriptRoot "ahu-connect.ps1"))) {
    throw "ahu-connect.ps1 not found next to install.ps1; run the installer from the extracted folder."
}

# --- Deploy engine files ---
Write-Step "Target directory: $HomeDirectory"
if (-not (Test-Path -LiteralPath $HomeDirectory)) {
    New-Item -ItemType Directory -Path $HomeDirectory -Force | Out-Null
}

$backupDirectory = Join-Path $HomeDirectory ("backup\" + (Get-Date -Format "yyyyMMdd-HHmmss"))
Backup-Existing (Join-Path $HomeDirectory "ahu-connect.ps1") $backupDirectory
Backup-Existing (Join-Path $HomeDirectory "run-hidden.vbs")   $backupDirectory

Copy-Item -LiteralPath (Join-Path $scriptRoot "ahu-connect.ps1") -Destination (Join-Path $HomeDirectory "ahu-connect.ps1") -Force
Copy-Item -LiteralPath (Join-Path $scriptRoot "run-hidden.vbs")   -Destination (Join-Path $HomeDirectory "run-hidden.vbs")   -Force
Write-Step "Deployed ahu-connect.ps1 and run-hidden.vbs"

# --- Credential config ---
$configPath = Join-Path $HomeDirectory "config.json"
if (Test-Path -LiteralPath $configPath) {
    Write-Step "Existing config.json kept untouched."
}
else {
    Write-Step "No config found; creating one."
    $campusUser     = Read-Host "Campus account (campus_user, Enter to skip)"
    $campusPass     = Read-Host "Campus password (campus_pass, Enter to skip)"
    $broadbandUser  = Read-Host "Broadband account (broadband_user, Enter to skip)"
    $broadbandPass  = Read-Host "Broadband password (broadband_pass, Enter to skip)"

    if (-not $campusUser -and -not $broadbandUser) {
        Write-Warning "No account entered; the config file is created from the example and must be filled in before auto login works."
        Copy-Item -LiteralPath (Join-Path $scriptRoot "config.example.json") -Destination $configPath -Force
    }
    else {
        $config = [ordered]@{
            campus_user         = $campusUser
            campus_pass         = $campusPass
            broadband_user      = $broadbandUser
            broadband_pass      = $broadbandPass
            portal_base         = "http://172.16.253.3:801/eportal/"
            check_host          = ""
            portal_check_hosts  = @("172.16.253.1", "172.16.253.3")
            campus_ip_prefixes  = @("10.", "172.16.", "172.21.", "172.29.")
            preferred_interfaces = @("Ethernet", "以太网")
            max_retries         = 10
            retry_interval_sec  = 10
            log_retention_days  = 30
        }
        $config | ConvertTo-Json | Set-Content -LiteralPath $configPath -Encoding UTF8
        Write-Step "config.json written to $configPath"
    }
    Write-Host "NOTE: config.json stores the credentials in plain text. Keep the folder private and never commit it."
}

$launcherPath = Join-Path $HomeDirectory "run-hidden.vbs"

# --- Logon entry ---
$runKeyPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
if (-not (Test-Path -LiteralPath $runKeyPath)) {
    New-Item -Path $runKeyPath -Force | Out-Null
}
$runCommand = "wscript.exe `"$launcherPath`""
New-ItemProperty -LiteralPath $runKeyPath -Name "AHU-Network-AutoConnect" -Value $runCommand -PropertyType String -Force | Out-Null
Write-Step "Registered logon Run key -> wscript.exe run-hidden.vbs"

# --- Scheduled tasks ---
if (-not $SkipScheduledTasks) {
    $taskAction = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "`"$launcherPath`""
    $principal  = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive
    $settings   = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 15) -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

    # Hourly keep-alive: idempotent portal answer within a few seconds.
    $hourlyTrigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(5) -RepetitionInterval (New-TimeSpan -Hours 1)
    Register-ScheduledTask -TaskName "AHU-Network-AutoConnect" -Action $taskAction -Trigger $hourlyTrigger -Principal $principal -Settings $settings -Force | Out-Null
    Write-Step "Registered task AHU-Network-AutoConnect (hourly, battery-friendly)"

    # Event trigger: NetworkProfile Event ID 10000 fires when a network connects.
    $subscription = "<QueryList><Query><Select Path='Microsoft-Windows-NetworkProfile/Operational'>*[System[Provider[@Name='Microsoft-Windows-NetworkProfile'] and EventID=10000]]</Select></Query></QueryList>"
    $eventClass   = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace ROOT/Microsoft/Windows/TaskScheduler
    $eventTrigger = New-CimInstance -CimClass $eventClass -ClientOnly
    $eventTrigger.Enabled      = $true
    $eventTrigger.Subscription = $subscription
    Register-ScheduledTask -TaskName "AHU-Network-AutoConnect-OnNetwork" -Action $taskAction -Trigger $eventTrigger -Principal $principal -Settings $settings -Force | Out-Null
    Write-Step "Registered task AHU-Network-AutoConnect-OnNetwork (network connect event)"
}

# --- Safe verification ---
if (-not $SkipVerification) {
    Write-Step "Running a read-only InspectOnly check (no login request is sent)..."
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $HomeDirectory "ahu-connect.ps1") -InspectOnly -Visible
    Write-Step "Done. InspectOnly exit code 0 = campus interface selected; 2 = no campus network right now (fine off campus)."
}

Write-Host ""
Write-Host "Install complete. Logs: $(Join-Path $HomeDirectory 'logs')"
Write-Host "Uninstall with: powershell -ExecutionPolicy Bypass -File uninstall.ps1"
