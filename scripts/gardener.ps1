<#
.SYNOPSIS
  Nightly tidy-up: runs Claude Code (claude -p) or Codex (codex exec) headless inside the vault, once
  per daily note that still has to be finalized, and prepares today's daily note at the end.
.DESCRIPTION
  Runs after the Hermes steps in nightly.ps1. The agent reads the fresh Hermes output and follows
  90_Meta/scripts/gardener-prompt.md: daily note, topic notes, project first pages, the
  #정리해줘 queue, at most one synthesis per night, the weekly note on Mondays, and the morning
  preparation of today's note.
  Settings come from config.json next to this script (written by install.ps1); parameters override them.
  Engine (config.json nightEngine): "claude", "codex", or empty = Claude if installed, else Codex.

  Which days (Get-DaysToRun):
    - -DailyDate given: that day only.
    - Otherwise every day after the last finalized one (gardener-state.json) up to yesterday,
      oldest first, at most MaxCatchUpDays (older missing days are logged and left to a manual
      run with -DailyDate). The first run ever (no state file) finalizes yesterday. When nothing
      is pending, today is refreshed.
    - Days run in order and the loop stops at the first failure, so a later day is never
      finalized before an earlier one. Only the last day's run prepares today's note
      (gardener-prompt 3-9); earlier runs get "Skip step 3-9".
    - After every successful day apply-topic-plan.ps1 applies the topic plan that run may have
      written, so two runs never overwrite each other's plan.
    - Only past days are recorded as finalized; a same-day refresh never moves the mark, so the
      next 03:00 run still finalizes that day.

  Budget (Claude only, Get-Workload): MaxBudgetUsd 0 = automatic: BaseBudgetUsd, plus PerLogUsd for
  each work log updated that day, PerCheckUsd for each permanent note or decision record created or
  updated that day (contradiction check), and on a Sunday daily PerSweepUsd for each note of the
  weekly full check; never above BudgetCeilingUsd, which only guards against a runaway run. A positive
  MaxBudgetUsd fixes the budget. A tight cap does not fail a run, the model quietly skips steps, so
  the cap is generous. Every run of either engine appends its workload to gardener-workload.csv for
  tuning; a Claude run also logs "WARN skipped for budget" when steps were skipped for budget.

  Plan usage limit (Claude only): when the subscription's 5-hour or weekly window stops a run, a
  one-time task "Hermes-Gardener-Retry" reruns this script 10 minutes after the reset time the CLI
  reports ("resets 5:10am", "resets Nov 20, 2pm"; 5 h 10 min later when no time is found). It picks
  up every day still pending. At most MaxRetries; the task deletes itself a day after it expires.
  When plan-usage.ps1 is present, each Claude run also logs what it took of the 5-hour and weekly
  limits.

  Claude safety rails:
    - gardener-settings.json: least privilege (no shell, no web, 99_Private unreadable,
      90_Meta and .obsidian read-only) and disableAllHooks (agent hooks would otherwise fire
      on every tool call and could answer permission requests).
    - --permission-prompts none: anything not explicitly allowed is denied, never waits.
    - --max-budget-usd caps spend per run.
    - --no-session-persistence: the run leaves no transcript, so it is never captured.
  Codex: sandbox workspace-write rooted at the vault, --ephemeral (no transcript). Codex has no
  per-path read deny, so 99_Private is protected only by the instruction text; README explains.
  Both engines: TimeoutMinutes kills a stuck run with its whole process tree, and a launch from
  inside a Claude, Codex or Orca session behaves like a fresh 03:00 run.
  Each run logs one summary line to hermes-inbox.log; after the last day every wikilink in the
  vault is checked once.
  -DryRun logs the days, tasks and budgets without calling the engine.
  Save as UTF-8 with BOM (PowerShell 5.1).
#>

[CmdletBinding()]
param(
  [string]$VaultPath = '',
  [string]$Engine = '',
  [string]$Model = '',
  [string]$FallbackModel = '',
  [string]$CodexModel = '',
  [double]$MaxBudgetUsd = 0,
  [double]$BaseBudgetUsd = 2.0,
  [double]$PerLogUsd = 0.1,
  [double]$PerCheckUsd = 0.3,
  [double]$PerSweepUsd = 0.05,
  [double]$BudgetCeilingUsd = 8.0,
  [int]$TimeoutMinutes = 40,
  [string]$DailyDate = '',
  [string]$TaskOverride = '',
  [int]$MaxCatchUpDays = 3,
  [int]$RetryCount = 0,
  [int]$MaxRetries = 3,
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$ScriptPath = $MyInvocation.MyCommand.Path
$ScriptDir  = Split-Path -Parent $ScriptPath
# Settings written by install.ps1 (read here: param defaults cannot see the script folder in PowerShell 5.1).
$KitConfig = $null
try { $KitConfig = Get-Content -LiteralPath (Join-Path $ScriptDir 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
if ($KitConfig) {
  if (-not $VaultPath) { $VaultPath = [string]$KitConfig.vaultPath }
  if (-not $Engine) { $Engine = [string]$KitConfig.nightEngine }
  if (-not $Model) { $Model = [string]$KitConfig.claudeModel }
  if (-not $FallbackModel) { $FallbackModel = [string]$KitConfig.claudeFallbackModel }
  if (-not $CodexModel) { $CodexModel = [string]$KitConfig.codexModel }
}
if (-not $VaultPath -or -not (Test-Path -LiteralPath $VaultPath)) { throw 'config.json is missing or vaultPath is wrong. Run install.ps1 first.' }
$LogPath     = Join-Path $ScriptDir 'hermes-inbox.log'
$LastOut     = Join-Path $ScriptDir 'gardener-last.json'
$StateFile   = Join-Path $ScriptDir 'gardener-state.json'
$WorkloadCsv = Join-Path $ScriptDir 'gardener-workload.csv'
$LastMsgRel  = '90_Meta/scripts/gardener-last.txt'   # Codex writes its last message here (relative to the vault)
$Inv         = [System.Globalization.CultureInfo]::InvariantCulture
$RetryTask   = 'Hermes-Gardener-Retry'

function Write-Log([string]$msg) {
  $line = '{0}  [gardener] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
  try { Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 } catch { }
  Write-Host $line   # host stream, so log lines never mix into a function's return value
}

# Pick the engine and find its executable.
$claudeCmd = Get-Command claude -ErrorAction SilentlyContinue
$ClaudeExe = if ($claudeCmd) { $claudeCmd.Source } else { Join-Path $env:USERPROFILE '.local\bin\claude.exe' }
# Only a runnable file: npm also installs codex.ps1, which cmd.exe would open in Notepad instead of running.
$codexCmd = Get-Command codex -CommandType Application -All -ErrorAction SilentlyContinue | Where-Object { $_.Source -match '\.(cmd|exe|bat)$' } | Select-Object -First 1
if (-not $Engine) { $Engine = $(if (Test-Path -LiteralPath $ClaudeExe) { 'claude' } elseif ($codexCmd) { 'codex' } else { '' }) }
if ($Engine -eq 'claude' -and -not (Test-Path -LiteralPath $ClaudeExe)) { Write-Log 'ERROR: claude CLI not found. Abort.'; exit 1 }
if ($Engine -eq 'codex' -and -not $codexCmd) { Write-Log 'ERROR: codex CLI not found. Abort.'; exit 1 }
if ($Engine -notin 'claude', 'codex') { Write-Log 'ERROR: neither claude nor codex CLI found. Abort.'; exit 1 }
$Engine = $Engine.ToLowerInvariant()
if ($DailyDate -ne '' -and $DailyDate -notmatch '^\d{4}-\d{2}-\d{2}$') { Write-Log 'ERROR: -DailyDate must be yyyy-MM-dd. Abort.'; exit 1 }

# ---------------------------------------------------------------- state and days

function Get-LastDone {
  if (-not (Test-Path -LiteralPath $StateFile)) { return '' }
  $d = ''
  try { $d = [string](Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json).lastDailyDate } catch { }
  if ($d -notmatch '^\d{4}-\d{2}-\d{2}$') { return '' }
  return $d
}

function Save-LastDone([string]$day) {
  # Only past days count as finalized; a same-day refresh never moves the mark, so 03:00 still finalizes it.
  $last = Get-LastDone
  if ($day -lt (Get-Date).ToString('yyyy-MM-dd', $Inv) -and ($last -eq '' -or $day -gt $last)) {
    try { (@{ lastDailyDate = $day } | ConvertTo-Json) | Set-Content -LiteralPath $StateFile -Encoding UTF8 } catch { }
  }
}

function Get-DaysToRun([string]$explicit, [string]$lastDone, [datetime]$now) {
  if ($explicit -ne '') { return @($explicit) }
  $today = $now.Date
  $yesterday = $today.AddDays(-1)
  if ($lastDone -eq '') { return @($yesterday.ToString('yyyy-MM-dd', $Inv)) }
  $last = [datetime]::ParseExact($lastDone, 'yyyy-MM-dd', $Inv)
  if ($last -ge $yesterday) { return @($today.ToString('yyyy-MM-dd', $Inv)) }   # nothing pending: refresh today
  $first = $last.AddDays(1)
  $oldestAllowed = $yesterday.AddDays(1 - [math]::Max(1, $MaxCatchUpDays))
  if ($first -lt $oldestAllowed) {
    Write-Log ("WARN {0} missed days before {1} are left unfinalized (MaxCatchUpDays={2}); run gardener.ps1 -DailyDate <day> for any that matter" -f ($oldestAllowed - $first).Days, $oldestAllowed.ToString('yyyy-MM-dd', $Inv), $MaxCatchUpDays)
    $first = $oldestAllowed
  }
  $days = @()
  for ($d = $first; $d -le $yesterday; $d = $d.AddDays(1)) { $days += $d.ToString('yyyy-MM-dd', $Inv) }
  return $days
}

# ---------------------------------------------------------------- workload and budget

function Get-FrontDate([string]$path, [string]$key) {
  try {
    $head = @(Get-Content -LiteralPath $path -TotalCount 25 -Encoding UTF8)
    if ($head.Count -lt 2 -or $head[0].Trim() -ne '---') { return '' }
    foreach ($l in $head[1..($head.Count - 1)]) {
      if ($l.Trim() -eq '---') { break }
      if ($l -match ('^' + $key + ':\s*["'']?(\d{4}-\d{2}-\d{2})')) { return $Matches[1] }
    }
  } catch { }
  return ''
}

function Get-Workload([string]$day) {
  # Read from frontmatter dates; 99_Private is never under these folders.
  $dd = [datetime]::ParseExact($day, 'yyyy-MM-dd', $Inv)
  $projRoot  = Join-Path $VaultPath '01_Projects'
  $notesRoot = Join-Path $VaultPath '02_Notes'
  $logFiles = @(); $knowFiles = @()
  if (Test-Path -LiteralPath $projRoot) {
    $md = @(Get-ChildItem -LiteralPath $projRoot -Recurse -File -Filter '*.md' -ErrorAction SilentlyContinue)
    $logFiles  = @($md | Where-Object { $_.FullName -match '\\log\\' })
    $knowFiles = @($md | Where-Object { $_.DirectoryName -match '\\decisions$' })
  }
  if (Test-Path -LiteralPath $notesRoot) {
    $knowFiles += @(Get-ChildItem -LiteralPath $notesRoot -Recurse -File -Filter '*.md' -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '작업-선호.md' })
  }
  $logs   = @($logFiles | Where-Object { (Get-FrontDate $_.FullName 'updated') -eq $day }).Count
  $checks = @($knowFiles | Where-Object { (Get-FrontDate $_.FullName 'updated') -eq $day -or (Get-FrontDate $_.FullName 'created') -eq $day }).Count
  $sweep  = 0
  if ($dd.DayOfWeek -eq [DayOfWeek]::Sunday) {
    # Weekly full check: every note up to 40; above that only the notes changed that week.
    $sweep = $knowFiles.Count
    if ($sweep -gt 40) {
      $monday = $dd.AddDays(-6).ToString('yyyy-MM-dd', $Inv)
      $sweep = @($knowFiles | Where-Object { $u = Get-FrontDate $_.FullName 'updated'; $u -ge $monday -and $u -le $day }).Count
    }
  }
  if ($MaxBudgetUsd -gt 0) { $value = $MaxBudgetUsd; $mode = 'fixed' }
  else {
    $value = [math]::Min([math]::Round($BaseBudgetUsd + $PerLogUsd * $logs + $PerCheckUsd * $checks + $PerSweepUsd * $sweep, 2), $BudgetCeilingUsd)
    $mode = 'auto'
  }
  return [pscustomobject]@{ Logs = $logs; Checks = $checks; Sweep = $sweep; Mode = $mode; Budget = $value.ToString($Inv) }
}

# ---------------------------------------------------------------- one run

function Get-TaskText([string]$day, [datetime]$now, [bool]$skipMorning) {
  if ($TaskOverride -ne '') { $t = $TaskOverride }
  else {
    $dd  = [datetime]::ParseExact($day, 'yyyy-MM-dd', $Inv)
    $dow = [int]$dd.DayOfWeek; if ($dow -eq 0) { $dow = 7 }          # Monday=1 ... Sunday=7
    $thu = $dd.AddDays(4 - $dow)                                       # ISO 8601: the week belongs to its Thursday's year
    $iso = '{0}-W{1:D2}' -f $thu.Year, ([int][math]::Floor(($thu.DayOfYear - 1) / 7) + 1)
    $t = "Read 90_Meta/scripts/gardener-prompt.md and carry out the nightly run exactly as it instructs. Run date: $($now.ToString('yyyy-MM-dd', $Inv)) ($($now.DayOfWeek)). Daily note date: $day ($($dd.DayOfWeek), ISO week $iso)."
    if ($skipMorning) { $t += ' Skip step 3-9 in this run.' }
  }
  if ($Engine -eq 'codex') {
    $t += ' Never open, read, list or search anything under 99_Private. Do not change files under 90_Meta or .obsidian. Do not run shell commands that change files outside the vault, and do not use the network.'
  }
  return $t
}

function Invoke-EngineRun([string]$task, [string]$budget) {
  # Returns ExitCode, Out, Err and Secs, or $null (with the reason logged) when the run timed out.
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  if ($Engine -eq 'claude') {
    $models = ''
    if ($Model) { $models += ' --model ' + $Model }
    if ($FallbackModel -and $FallbackModel -ne $Model) { $models += ' --fallback-model ' + $FallbackModel }
    $psi.FileName = $ClaudeExe
    $psi.Arguments = ('-p "{0}"{1} --settings 90_Meta/scripts/gardener-settings.json --permission-prompts none --disallowedTools Bash WebFetch WebSearch --max-budget-usd {2} --no-session-persistence --strict-mcp-config --output-format json' -f $task, $models, $budget)
  } else {
    # npm installs codex as a .cmd shim; run it through cmd.exe. The vault is the working directory
    # and every path in the arguments is relative, so a non-ASCII vault path never hits the command line.
    $modelArg = if ($CodexModel) { ' -m ' + $CodexModel } else { '' }
    $psi.FileName = Join-Path $env:SystemRoot 'System32\cmd.exe'
    $psi.Arguments = ('/d /s /c ""{0}" exec -s workspace-write -C . --skip-git-repo-check --ephemeral --color never -o {1}{2} "{3}""' -f $codexCmd.Source, $LastMsgRel, $modelArg, $task)
  }
  $psi.WorkingDirectory = $VaultPath
  $psi.UseShellExecute = $false
  $psi.RedirectStandardInput = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
  $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
  # Behave like a fresh 03:00 launch even when started from inside a Claude, Codex or Orca session.
  foreach ($k in @($psi.EnvironmentVariables.Keys)) {
    if ($k -match '^(CLAUDECODE|CLAUDE_CODE_ENTRYPOINT|CLAUDE_CODE_SSE_PORT|CODEX_SANDBOX.*|CODEX_THREAD_ID|ORCA_.*)$') { $psi.EnvironmentVariables.Remove($k) }
  }

  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $p = [System.Diagnostics.Process]::Start($psi)
  $p.StandardInput.Close()   # EOF on stdin so the CLI never waits for piped input
  $outTask = $p.StandardOutput.ReadToEndAsync()
  $errTask = $p.StandardError.ReadToEndAsync()
  if (-not $p.WaitForExit($TimeoutMinutes * 60 * 1000)) {
    # Kill the whole tree: for Codex the direct child is cmd.exe and the agent runs below it.
    try { & taskkill.exe /PID $p.Id /T /F 2>&1 | Out-Null } catch { }
    try { $p.Kill() } catch { }
    [void]$p.WaitForExit(10000)
    $tail = ''
    try { $tail = (($errTask.Result + ' ' + $outTask.Result) -replace '\s+', ' ').Trim() } catch { }
    if ($tail.Length -gt 300) { $tail = '...' + $tail.Substring($tail.Length - 300) }
    Write-Log "ERROR: timeout after $TimeoutMinutes min, process tree killed. last output: $tail"
    return $null
  }
  $p.WaitForExit()
  $sw.Stop()
  return [pscustomobject]@{ ExitCode = $p.ExitCode; Out = $outTask.Result; Err = $errTask.Result; Secs = [math]::Round($sw.Elapsed.TotalSeconds) }
}

function Invoke-GardenerDay([string]$day, [bool]$skipMorning) {
  # Returns 'ok', 'limit:<message>' (Claude plan usage limit) or 'fail'.
  $task = Get-TaskText $day (Get-Date) $skipMorning
  if ($task.Contains('"')) { Write-Log 'ERROR: task text must not contain double quotes.'; return 'fail' }
  $w = Get-Workload $day
  $load = "logs=$($w.Logs) checks=$($w.Checks) sweep=$($w.Sweep)"
  if ($Engine -eq 'claude') { $who = "model=$Model budget_usd=$($w.Budget) ($($w.Mode) $load)" }
  else { $who = $(if ($CodexModel) { "model=$CodexModel " } else { '' }) + "($load)" }
  Write-Log ("start engine={0} {1} daily={2}{3}" -f $Engine, $who, $day, $(if ($skipMorning) { ' skip-3-9' } else { '' }))
  if ($DryRun) { Write-Log "dry run: $task"; return 'ok' }

  $useUsage = $script:HasUsage -and ($Engine -eq 'claude')
  $usageBefore = $null; $usageStart = Get-Date
  if ($useUsage) { $usageBefore = Get-PlanUsage }
  $lastMsg = Join-Path $VaultPath $LastMsgRel
  if ($Engine -eq 'codex' -and (Test-Path -LiteralPath $lastMsg)) { try { Remove-Item -LiteralPath $lastMsg -Force } catch { } }   # never report an earlier day's message

  $r = Invoke-EngineRun $task $w.Budget
  if ($null -eq $r) { return 'fail' }
  $status = 'ok'; $cost = ''; $turns = ''; $hit = ''
  if ($Engine -eq 'claude') {
    try { [System.IO.File]::WriteAllText($LastOut, $r.Out, (New-Object System.Text.UTF8Encoding($false))) } catch { }
    $j = $null
    try { $j = $r.Out | ConvertFrom-Json } catch { }
    if ($null -eq $j) {
      $e = ($r.Err -replace '\s+', ' ').Trim()
      if ($e.Length -gt 300) { $e = $e.Substring(0, 300) }
      Write-Log ("FAIL exit={0} no JSON output. stderr: {1}" -f $r.ExitCode, $e)
      return 'fail'
    }
    $cost = $j.total_cost_usd
    if ($null -eq $cost) { $cost = $j.cost_usd }
    $turns = $j.num_turns
    $result = [string]$j.result
    $res = ($result -replace '\s+', ' ').Trim()
    if ($res.Length -gt 400) { $res = $res.Substring(0, 400) + '...' }
    Write-Log ("Done. is_error={0} turns={1} cost_usd={2} secs={3} | {4}" -f [bool]$j.is_error, $turns, $cost, $r.Secs, $res)

    # A budget that runs short shows up as skipped steps (the run still ends without an error) or as an
    # error subtype; either way it is logged so it never passes silently.
    $skipLine = ''
    foreach ($l in ($result -split "`r?`n")) { if ($l -match '^\s*건너뜀\s*:') { $skipLine = $l.Trim() } }
    $hit = ([string]$j.subtype -match 'budget') -or ($skipLine -match '예산|비용|budget')
    if ($hit) { Write-Log ("WARN skipped for budget (budget_usd={0}, cost_usd={1}): {2} {3}" -f $w.Budget, $cost, $j.subtype, $skipLine) }
    if ($j.is_error) { $status = $(if (-not $hit -and $result -match 'limit') { 'limit:' + $result.Trim() } else { 'fail' }) }
  } else {
    $res = ''
    if (Test-Path -LiteralPath $lastMsg) { $res = ([System.IO.File]::ReadAllText($lastMsg, [System.Text.Encoding]::UTF8) -replace '\s+', ' ').Trim() }
    if ($r.ExitCode -ne 0 -and $res -eq '') { $res = 'stderr: ' + (($r.Err -replace '\s+', ' ').Trim()) }
    if ($res.Length -gt 400) { $res = $res.Substring(0, 400) + '...' }
    Write-Log ("Done. is_error={0} exit={1} secs={2} | {3}" -f ($r.ExitCode -ne 0), $r.ExitCode, $r.Secs, $res)
    if ($r.ExitCode -ne 0) { $status = 'fail' }
  }

  # One row per run for tuning the budget; budget columns stay empty for Codex.
  try {
    if (-not (Test-Path -LiteralPath $WorkloadCsv)) { Add-Content -LiteralPath $WorkloadCsv -Encoding UTF8 -Value 'run_at,daily,engine,logs,checks,sweep,budget_mode,budget_usd,cost_usd,turns,secs,budget_hit' }
    $mode = ''; $bud = ''
    if ($Engine -eq 'claude') { $mode = $w.Mode; $bud = $w.Budget }
    Add-Content -LiteralPath $WorkloadCsv -Encoding UTF8 -Value (@((Get-Date -Format 'yyyy-MM-dd HH:mm'), $day, $Engine, $w.Logs, $w.Checks, $w.Sweep, $mode, $bud, $cost, $turns, $r.Secs, $hit) -join ',')
  } catch { Write-Log ('workload: ' + $_.Exception.Message) }
  # Plan usage before and after the run (what /usage shows), to measure what one run costs of the limits.
  if ($useUsage) { try { Write-PlanUsage $usageBefore $usageStart $day $cost $r.Secs ${function:Write-Log} $ScriptDir } catch { Write-Log ('usage: ' + $_.Exception.Message) } }
  return $status
}

# ---------------------------------------------------------------- retry after the plan usage limit

function Get-ResetTime([string]$msg, [datetime]$from) {
  $m = [regex]::Match($msg, 'resets\s+(?:(?<mon>[A-Za-z]{3})[a-z]*\s+(?<day>\d{1,2}),?\s+(?:at\s+)?)?(?<h>\d{1,2})(?::(?<mi>\d{2}))?\s*(?<ap>am|pm)', 'IgnoreCase')
  if (-not $m.Success) { return $null }
  $h = [int]$m.Groups['h'].Value % 12
  if ($m.Groups['ap'].Value -match '^(?i)pm$') { $h += 12 }
  $mi = $(if ($m.Groups['mi'].Success) { [int]$m.Groups['mi'].Value } else { 0 })
  if ($m.Groups['mon'].Success) {
    $mon = [datetime]::ParseExact($m.Groups['mon'].Value.Substring(0, 1).ToUpper() + $m.Groups['mon'].Value.Substring(1, 2).ToLower(), 'MMM', $Inv).Month
    $t = New-Object DateTime ($from.Year, $mon, [int]$m.Groups['day'].Value, $h, $mi, 0)
    if ($t -lt $from.AddDays(-1)) { $t = $t.AddYears(1) }
  } else {
    $t = $from.Date.AddHours($h).AddMinutes($mi)
    if ($t -le $from) { $t = $t.AddDays(1) }
  }
  return $t
}

function Register-GardenerRetry([string]$msg) {
  if ($RetryCount -ge $MaxRetries) { Write-Log "WARN plan usage limit: gave up after $RetryCount retries; pending days wait for the next nightly run"; return }
  $reset = Get-ResetTime $msg (Get-Date)
  $at = $(if ($null -ne $reset) { $reset.AddMinutes(10) } else { (Get-Date).AddHours(5).AddMinutes(10) })
  $arg = ('-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -VaultPath "{1}" -Engine claude -RetryCount {2}' -f $ScriptPath, $VaultPath.TrimEnd('\'), ($RetryCount + 1))
  if ($DryRun) { Write-Log "dry run: would schedule $RetryTask at $($at.ToString('yyyy-MM-dd HH:mm', $Inv)) with: $arg"; return }
  try {
    $action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $arg
    $trigger   = New-ScheduledTaskTrigger -Once -At $at
    $trigger.EndBoundary = $at.AddHours(12).ToString('s', $Inv)
    $settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 3) -MultipleInstances IgnoreNew -DeleteExpiredTaskAfter (New-TimeSpan -Days 1)
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Limited
    if (Get-ScheduledTask -TaskName $RetryTask -ErrorAction SilentlyContinue) { Unregister-ScheduledTask -TaskName $RetryTask -Confirm:$false }
    Register-ScheduledTask -TaskName $RetryTask -Action $action -Trigger $trigger -Settings $settings -Principal $principal `
      -Description 'One-time retry of the nightly gardener after the plan usage limit resets.' | Out-Null
    Write-Log ("retry {0}/{1} scheduled at {2} (task {3})" -f ($RetryCount + 1), $MaxRetries, $at.ToString('yyyy-MM-dd HH:mm', $Inv), $RetryTask)
  } catch { Write-Log ('WARN retry not scheduled: ' + $_.Exception.Message) }
}

# ---------------------------------------------------------------- after the runs

function Invoke-TopicPlan {
  # Apply the topic plan a run may have written before the next run plans again.
  $s = Join-Path $ScriptDir 'apply-topic-plan.ps1'
  if ($DryRun -or -not (Test-Path -LiteralPath $s)) { return }
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $s -VaultPath $VaultPath | Out-Null
  if ($LASTEXITCODE -ne 0) { Write-Log "WARN apply-topic-plan.ps1 exit=$LASTEXITCODE" }
}

function Test-VaultLinks {
  # Logged, never fatal: every wikilink in the content notes must resolve, and empty notes are
  # reported (Obsidian creates one at the vault root when a broken link is clicked).
  try {
    $all = @(Get-ChildItem -LiteralPath $VaultPath -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch '\\\.obsidian\\' })
    $names = @{}
    foreach ($f in $all) {
      $names[$f.Name.ToLowerInvariant()] = $true
      if ($f.Extension -eq '.md') { $names[$f.BaseName.ToLowerInvariant()] = $true }
    }
    $notes = @($all | Where-Object { $_.Extension -eq '.md' -and $_.FullName -notmatch '\\(\.obsidian|99_Private|90_Meta)\\' })
    $missing = @(); $empty = @()
    foreach ($f in $notes) {
      if ($f.Length -eq 0) { $empty += $f.FullName.Substring($VaultPath.Length).TrimStart('\'); continue }
      $t = [System.IO.File]::ReadAllText($f.FullName, [System.Text.Encoding]::UTF8)
      $t = [regex]::Replace($t, '(?ms)^(`{3,}|~{3,}).*?^\1', '')
      $t = [regex]::Replace($t, '`[^`\r\n]*`', '')
      foreach ($l in [regex]::Matches($t, '\[\[([^\]\|#\^]+)')) {
        $n = ($l.Groups[1].Value.Trim() -split '/')[-1]
        if ($n -ne '' -and -not $names.ContainsKey($n.ToLowerInvariant())) { $missing += ($f.BaseName + ': ' + $n) }
      }
    }
    $missing = @($missing | Select-Object -Unique)
    if ($missing.Count -gt 0) { Write-Log ('WARN unresolved links: ' + (($missing | Select-Object -First 30) -join ' | ')) } else { Write-Log 'links ok' }
    if ($empty.Count -gt 0) { Write-Log ('WARN empty notes: ' + ($empty -join ' | ')) }
  } catch { Write-Log ('WARN link check failed: ' + $_.Exception.Message) }
}

# ---------------------------------------------------------------- main

$script:HasUsage = $false
$pu = Join-Path $ScriptDir 'plan-usage.ps1'
if ($Engine -eq 'claude' -and (Test-Path -LiteralPath $pu)) { . $pu; $script:HasUsage = $true }

$now      = Get-Date
$today    = $now.ToString('yyyy-MM-dd', $Inv)
$lastDone = Get-LastDone
$days     = @(Get-DaysToRun $DailyDate $lastDone $now)
if ($RetryCount -gt 0 -and $DailyDate -eq '' -and $days.Count -eq 1 -and $days[0] -eq $today) {
  Write-Log "retry $RetryCount skipped: no day left to finalize (last=$lastDone)"
  exit 0
}
if ($days.Count -gt 1) { Write-Log ('catch-up: ' + ($days -join ', ')) }

$failed = $false
for ($i = 0; $i -lt $days.Count; $i++) {
  $status = Invoke-GardenerDay $days[$i] ($i -lt $days.Count - 1)
  if ($status -eq 'ok') {
    if (-not $DryRun) { Save-LastDone $days[$i] }
    Invoke-TopicPlan
    continue
  }
  $failed = $true
  if ($status -like 'limit:*') {
    Write-Log ('WARN plan usage limit reached, run stopped early for ' + $days[$i] + ': ' + $status.Substring(6))
    Register-GardenerRetry $status.Substring(6)
  }
  if ($i -lt $days.Count - 1) { Write-Log ('stopped: ' + (($days[($i + 1)..($days.Count - 1)]) -join ', ') + ' wait for the next run') }
  break
}
Test-VaultLinks
if ($failed) { exit 1 }
