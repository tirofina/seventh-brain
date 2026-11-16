<#
.SYNOPSIS
  Nightly tidy-up: runs Claude Code (claude -p) or Codex (codex exec) headless inside the vault.
.DESCRIPTION
  Runs after the Hermes steps in nightly.ps1. The agent reads the fresh Hermes output and follows
  90_Meta/scripts/gardener-prompt.md: daily note, topic notes, project first pages, the
  #정리해줘 queue, at most one synthesis per night, the weekly note on Mondays.
  Engine (config.json nightEngine): "claude", "codex", or empty = Claude if installed, else Codex.
  Claude safety rails:
    - gardener-settings.json: least privilege (no shell, no web, 99_Private unreadable,
      90_Meta and .obsidian read-only) and disableAllHooks (agent hooks would otherwise fire
      on every tool call and could answer permission requests).
    - --permission-prompts none: anything not explicitly allowed is denied, never waits.
    - --max-budget-usd caps spend per run; TimeoutMinutes kills a stuck run.
    - --no-session-persistence: the run leaves no transcript, so it is never captured.
  Codex: sandbox workspace-write rooted at the vault, --ephemeral (no transcript). Codex has no
  per-path read deny, so 99_Private is protected only by the instruction text; README explains.
  One summary line goes to hermes-inbox.log, then every wikilink in the vault is checked.
#>

[CmdletBinding()]
param(
  [string]$VaultPath = '',
  [string]$Engine = '',
  [string]$Model = '',
  [string]$FallbackModel = '',
  [string]$CodexModel = '',
  [double]$MaxBudgetUsd = 1.0,
  [int]$TimeoutMinutes = 20,
  [string]$DailyDate = '',
  [string]$TaskOverride = ''
)

$ErrorActionPreference = 'Stop'
# Settings written by install.ps1 (read here: param defaults cannot see the script folder in PowerShell 5.1).
$KitConfig = $null
try { $KitConfig = Get-Content -LiteralPath (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
if ($KitConfig) {
  if (-not $VaultPath) { $VaultPath = [string]$KitConfig.vaultPath }
  if (-not $Engine) { $Engine = [string]$KitConfig.nightEngine }
  if (-not $Model) { $Model = [string]$KitConfig.claudeModel }
  if (-not $FallbackModel) { $FallbackModel = [string]$KitConfig.claudeFallbackModel }
  if (-not $CodexModel) { $CodexModel = [string]$KitConfig.codexModel }
}
if (-not $VaultPath -or -not (Test-Path -LiteralPath $VaultPath)) { throw 'config.json is missing or vaultPath is wrong. Run install.ps1 first.' }
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogPath   = Join-Path $ScriptDir 'hermes-inbox.log'
$LastOut   = Join-Path $ScriptDir 'gardener-last.json'

function Write-Log([string]$msg) {
  $line = '{0}  [gardener] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
  try { Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 } catch { }
  Write-Output $line
}

# Pick the engine and find its executable.
$claudeCmd = Get-Command claude -ErrorAction SilentlyContinue
$claude = if ($claudeCmd) { $claudeCmd.Source } else { Join-Path $env:USERPROFILE '.local\bin\claude.exe' }
# Only a runnable file: npm also installs codex.ps1, which cmd.exe would open in Notepad instead of running.
$codexCmd = Get-Command codex -CommandType Application -All -ErrorAction SilentlyContinue | Where-Object { $_.Source -match '\.(cmd|exe|bat)$' } | Select-Object -First 1
if (-not $Engine) { $Engine = $(if (Test-Path -LiteralPath $claude) { 'claude' } elseif ($codexCmd) { 'codex' } else { '' }) }
if ($Engine -eq 'claude' -and -not (Test-Path -LiteralPath $claude)) { Write-Log 'ERROR: claude CLI not found. Abort.'; exit 1 }
if ($Engine -eq 'codex' -and -not $codexCmd) { Write-Log 'ERROR: codex CLI not found. Abort.'; exit 1 }
if ($Engine -notin 'claude', 'codex') { Write-Log 'ERROR: neither claude nor codex CLI found. Abort.'; exit 1 }

# Finalize yesterday if it has not been finalized yet (the normal 03:00 run, or a catch-up run
# after the PC was off or asleep at 03:00); otherwise refresh today.
$StateFile = Join-Path $ScriptDir 'gardener-state.json'
$lastDone = ''
if (Test-Path -LiteralPath $StateFile) { try { $lastDone = [string](Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json).lastDailyDate } catch { } }
$now = Get-Date
if ($DailyDate -eq '') {
  $yesterday = $now.AddDays(-1).ToString('yyyy-MM-dd')
  $DailyDate = $(if ($lastDone -eq '' -or $lastDone -lt $yesterday) { $yesterday } else { $now.ToString('yyyy-MM-dd') })
}
$runDate = $now.ToString('yyyy-MM-dd')

$dd  = [datetime]::ParseExact($DailyDate, 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
$dow = [int]$dd.DayOfWeek; if ($dow -eq 0) { $dow = 7 }          # Monday=1 ... Sunday=7
$thu = $dd.AddDays(4 - $dow)                                       # ISO 8601: the week belongs to its Thursday's year
$isoTag  = '{0}-W{1:D2}' -f $thu.Year, ([int][math]::Floor(($thu.DayOfYear - 1) / 7) + 1)
$weekday = $dd.DayOfWeek.ToString()
$task = if ($TaskOverride -ne '') { $TaskOverride } else {
  "Read 90_Meta/scripts/gardener-prompt.md and carry out the nightly run exactly as it instructs. Run date: $runDate. Daily note date: $DailyDate ($weekday, ISO week $isoTag)."
}
if ($Engine -eq 'codex') {
  $task += ' Never open, read, list or search anything under 99_Private. Do not change files under 90_Meta or .obsidian. Do not run shell commands that change files outside the vault, and do not use the network.'
}
if ($task.Contains('"')) { Write-Log 'ERROR: task text must not contain double quotes.'; exit 1 }

$budget = $MaxBudgetUsd.ToString([System.Globalization.CultureInfo]::InvariantCulture)
$lastMsgRel = '90_Meta/scripts/gardener-last.txt'
if ($Engine -eq 'claude') {
  $file = $claude
  $argLine = ('-p "{0}" --model {1} --fallback-model {2} --settings 90_Meta/scripts/gardener-settings.json --permission-prompts none --disallowedTools Bash WebFetch WebSearch --max-budget-usd {3} --no-session-persistence --strict-mcp-config --output-format json' -f $task, $Model, $FallbackModel, $budget)
} else {
  # npm installs codex as a .cmd shim; run it through cmd.exe. The vault is the working directory
  # and every path in the arguments is relative, so a non-ASCII vault path never hits the command line.
  $file = Join-Path $env:SystemRoot 'System32\cmd.exe'
  $modelArg = if ($CodexModel) { ' -m ' + $CodexModel } else { '' }
  $argLine = ('/d /s /c ""{0}" exec -s workspace-write -C . --skip-git-repo-check --ephemeral --color never -o {1}{2} "{3}""' -f $codexCmd.Source, $lastMsgRel, $modelArg, $task)
}

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $file
$psi.Arguments = $argLine
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

$who = if ($Engine -eq 'claude') { "model=$Model budget_usd=$budget" } else { 'codex' + $(if ($CodexModel) { " model=$CodexModel" } else { '' }) }
Write-Log "start engine=$Engine $who daily=$DailyDate"
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
  exit 1
}
$p.WaitForExit()
$sw.Stop()
$out = $outTask.Result
$err = $errTask.Result
$secs = [math]::Round($sw.Elapsed.TotalSeconds)

if ($Engine -eq 'claude') {
  try { [System.IO.File]::WriteAllText($LastOut, $out, (New-Object System.Text.UTF8Encoding($false))) } catch { }
  $j = $null
  try { $j = $out | ConvertFrom-Json } catch { }
  if ($null -eq $j) {
    $e = ($err -replace '\s+', ' ').Trim()
    if ($e.Length -gt 300) { $e = $e.Substring(0, 300) }
    Write-Log ("FAIL exit={0} no JSON output. stderr: {1}" -f $p.ExitCode, $e)
    exit 1
  }
  $isError = [bool]$j.is_error
  $cost = $j.total_cost_usd
  if ($null -eq $cost) { $cost = $j.cost_usd }
  $res = ([string]$j.result -replace '\s+', ' ').Trim()
  if ($res.Length -gt 400) { $res = $res.Substring(0, 400) + '...' }
  Write-Log ("Done. is_error={0} turns={1} cost_usd={2} secs={3} | {4}" -f $isError, $j.num_turns, $cost, $secs, $res)
} else {
  $isError = ($p.ExitCode -ne 0)
  $lastMsg = Join-Path $VaultPath $lastMsgRel
  $res = ''
  if (Test-Path -LiteralPath $lastMsg) { $res = ([System.IO.File]::ReadAllText($lastMsg, [System.Text.Encoding]::UTF8) -replace '\s+', ' ').Trim() }
  if ($isError -and $res -eq '') { $res = 'stderr: ' + (($err -replace '\s+', ' ').Trim()) }
  if ($res.Length -gt 400) { $res = $res.Substring(0, 400) + '...' }
  Write-Log ("Done. is_error={0} exit={1} secs={2} | {3}" -f $isError, $p.ExitCode, $secs, $res)
}

# Post-check (logged, never fatal): every wikilink in the content notes must resolve, and empty
# notes are reported (Obsidian creates one at the vault root when a broken link is clicked).
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
# Remember the last finalized past day (never record a same-day refresh, so 03:00 still finalizes it).
if (-not $isError -and $DailyDate -lt $runDate -and ($lastDone -eq '' -or $DailyDate -gt $lastDone)) {
  try { (@{ lastDailyDate = $DailyDate } | ConvertTo-Json) | Set-Content -LiteralPath $StateFile -Encoding UTF8 } catch { }
}
if ($isError) { exit 1 }
