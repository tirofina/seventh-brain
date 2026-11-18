<#
.SYNOPSIS
  Register (or refresh) the nightly Hermes pipeline in Windows Task Scheduler.
.DESCRIPTION
  Creates a per-user task that runs nightly.ps1 every night at 03:00
  (capture work sessions, then process the Inbox). Runs as the current user with
  LogonType Interactive, so no admin rights and no stored password are needed. The
  task only fires while the user is logged on; StartWhenAvailable lets a missed run
  catch up after the PC wakes. Re-running this script replaces the existing task.
#>

$ErrorActionPreference = 'Stop'
$TaskName = 'Hermes-Inbox-Nightly'
$Script   = Join-Path $PSScriptRoot 'nightly.ps1'
$At       = '3:00AM'

$action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}"' -f $Script)
$trigger   = New-ScheduledTaskTrigger -Daily -At $At
$settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 3) -MultipleInstances IgnoreNew
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited

if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
  Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}

Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
  -Description 'Nightly local-Hermes pipeline: capture Claude Code sessions, then tag/summarize Obsidian 00_Inbox notes.' | Out-Null

Write-Output "Registered scheduled task: $TaskName (daily at $At, user=$env:USERNAME, runs nightly.ps1)"
