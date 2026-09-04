[CmdletBinding()]
param(
    [ValidatePattern('^([01]\d|2[0-3]):[0-5]\d$')]
    [string]$At = '02:00'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$TaskName = 'QuickkNastyy Profile Stats Refresh'
$RefreshScript = Join-Path $PSScriptRoot 'refresh-stats.ps1'
$PowerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$UserId = "$env:USERDOMAIN\$env:USERNAME"

if (-not (Test-Path $RefreshScript)) { throw "Refresh script not found: $RefreshScript" }
if (-not (Test-Path $PowerShellExe)) { throw "Windows PowerShell not found: $PowerShellExe" }

$atTime = [DateTime]::ParseExact($At, 'HH:mm', [Globalization.CultureInfo]::InvariantCulture)
$actionArguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -Scheduled' -f $RefreshScript
$action = New-ScheduledTaskAction -Execute $PowerShellExe -Argument $actionArguments -WorkingDirectory (Split-Path -Parent $PSScriptRoot)
$trigger = New-ScheduledTaskTrigger -Daily -At $atTime
$principal = New-ScheduledTaskPrincipal -UserId $UserId -LogonType Interactive -RunLevel Limited
$settings = New-ScheduledTaskSettingsSet `
    -StartWhenAvailable `
    -WakeToRun `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -MultipleInstances IgnoreNew `
    -ExecutionTimeLimit (New-TimeSpan -Minutes 20) `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 10)

$task = New-ScheduledTask `
    -Action $action `
    -Trigger $trigger `
    -Principal $principal `
    -Settings $settings `
    -Description 'Refresh QuickkNastyy GitHub profile stats locally, commit only assets/stats.svg when changed, and push to the profile repository.'

Register-ScheduledTask -TaskName $TaskName -InputObject $task -Force | Out-Null

$installed = Get-ScheduledTask -TaskName $TaskName
$info = Get-ScheduledTaskInfo -TaskName $TaskName
Write-Host "Installed Scheduled Task: $TaskName"
Write-Host "User: $UserId"
Write-Host "Daily local time: $At"
Write-Host "StartWhenAvailable: $($installed.Settings.StartWhenAvailable)"
Write-Host "WakeToRun: $($installed.Settings.WakeToRun)"
Write-Host "Next run: $($info.NextRunTime)"
Write-Host 'The task contains no GitHub token or other secret in its arguments.'
Write-Host 'It runs without a terminal window while this Windows user has an interactive logon session.'
