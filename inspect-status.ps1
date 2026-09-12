<#
Read-only AHU automation status collector.

Reports deployed file existence, scheduled-task actions and triggers, the
startup entry, and recent log activity as JSON. It deliberately never opens
the credential config and never calls the AHU Portal.

Example:
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\inspect-status.ps1
#>
[CmdletBinding()]
param(
    [string]$HomeDirectory = "$env:APPDATA\ahu-network"
)

$ErrorActionPreference = "Stop"


function Get-AutomationTasks {
    $tasks = @(Get-ScheduledTask -TaskName "AHU-Network-AutoConnect*" -ErrorAction SilentlyContinue)

    return @($tasks | Sort-Object TaskName | ForEach-Object {
        $info     = $_ | Get-ScheduledTaskInfo -ErrorAction SilentlyContinue
        $taskXml  = $null
        try { $taskXml = [xml]($_ | Export-ScheduledTask) } catch { }

        $batteryFriendly = $null
        if ($taskXml -and $taskXml.Task.Settings.DisallowStartIfOnBatteries) {
            $batteryFriendly = ($taskXml.Task.Settings.DisallowStartIfOnBatteries -eq "false")
        }

        [ordered]@{
            name                  = $_.TaskName
            state                 = [string]$_.State
            execute               = [string](($_.Actions | ForEach-Object { $_.Execute }) -join ";")
            arguments             = [string](($_.Actions | ForEach-Object { $_.Arguments }) -join ";")
            trigger_count         = @($_.Triggers).Count
            last_run_time         = if ($info) { [string]$info.LastRunTime } else { "" }
            last_task_result      = if ($info) { [int]$info.LastTaskResult } else { $null }
            runs_on_battery       = $batteryFriendly
        }
    })
}


function Get-LatestLogSummary {
    $logDirectory = Join-Path $HomeDirectory "logs"
    $latest = Get-ChildItem -LiteralPath $logDirectory -Filter "*.log" -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if (-not $latest) {
        return $null
    }

    $tail = Get-Content -LiteralPath $latest.FullName -Tail 5 -ErrorAction SilentlyContinue
    return [ordered]@{
        latest_log = $latest.Name
        size_bytes = $latest.Length
        tail       = @($tail)
    }
}


function Get-AHUAutomationStatus {
    $runKeyPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
    $runValue   = Get-ItemProperty -LiteralPath $runKeyPath -Name "AHU-Network-AutoConnect" -ErrorAction SilentlyContinue

    $warnings = @()
    if (-not (Test-Path -LiteralPath (Join-Path $HomeDirectory "ahu-connect.ps1"))) {
        $warnings += "Deployed automation script is missing."
    }
    if (-not (Test-Path -LiteralPath (Join-Path $HomeDirectory "config.json"))) {
        $warnings += "Credential config is missing; its contents were not read."
    }

    foreach ($task in (Get-AutomationTasks)) {
        if ($null -ne $task.runs_on_battery -and -not $task.runs_on_battery) {
            $warnings += "Task $($task.name) will not start on battery power (DisallowStartIfOnBatteries=true)."
        }
    }

    return [ordered]@{
        schema_version = 2
        host           = [ordered]@{
            powershell_version = $PSVersionTable.PSVersion.ToString()
        }
        automation = [ordered]@{
            install_directory       = $HomeDirectory
            script_exists           = Test-Path -LiteralPath (Join-Path $HomeDirectory "ahu-connect.ps1")
            config_exists           = Test-Path -LiteralPath (Join-Path $HomeDirectory "config.json")
            launcher_exists         = Test-Path -LiteralPath (Join-Path $HomeDirectory "run-hidden.vbs")
            log_directory_exists    = Test-Path -LiteralPath (Join-Path $HomeDirectory "logs")
            scheduled_tasks         = Get-AutomationTasks
            startup_command_present = [bool]$runValue
            latest_log              = Get-LatestLogSummary
        }
        secrets_read  = $false
        changes_made  = $false
        warnings      = $warnings
    }
}


try {
    Get-AHUAutomationStatus | ConvertTo-Json -Depth 8
}
catch {
    [Console]::Error.WriteLine("Status inspection failed: {0}" -f $_.Exception.Message)
    exit 1
}
