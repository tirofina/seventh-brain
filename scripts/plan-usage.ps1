<#
.SYNOPSIS
  Read the Claude plan usage that /usage shows (5-hour window and weekly), for the subscription the
  local Claude Code login belongs to. Dot-source it: . (Join-Path $ScriptDir 'plan-usage.ps1')
.DESCRIPTION
  Uses the access token in ~/.claude/.credentials.json and asks Anthropic's usage endpoint, the same
  place /usage reads from. The token is sent only to api.anthropic.com and is never logged. When the
  token has expired, `claude auth status` is run once so the CLI can refresh it. Values are whole
  percents. Returns $null when the usage cannot be read (API-key login, no network, endpoint change).
  Save as UTF-8 with BOM (PowerShell 5.1).
#>
function Get-PlanUsage {
  $cred = Join-Path $env:USERPROFILE '.claude\.credentials.json'
  if (-not (Test-Path -LiteralPath $cred)) { return $null }
  for ($attempt = 0; $attempt -lt 2; $attempt++) {
    try {
      $o = (Get-Content -LiteralPath $cred -Raw | ConvertFrom-Json).claudeAiOauth
      if (-not $o -or -not $o.accessToken) { return $null }
      $expired = ([DateTimeOffset]::FromUnixTimeMilliseconds([long]$o.expiresAt)).UtcDateTime -lt (Get-Date).ToUniversalTime().AddMinutes(1)
      if ($expired -and $attempt -eq 0) {
        $c = Get-Command claude -ErrorAction SilentlyContinue
        if ($c) { & $c.Source auth status 2>&1 | Out-Null }
        continue
      }
      [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
      $r = Invoke-RestMethod -Uri 'https://api.anthropic.com/api/oauth/usage' -Headers @{ Authorization = 'Bearer ' + $o.accessToken; 'anthropic-beta' = 'oauth-2025-04-20' } -TimeoutSec 20
      if ($null -eq $r.five_hour) { return $null }
      return [pscustomobject]@{
        Five = [double]$r.five_hour.utilization; FiveReset = [string]$r.five_hour.resets_at
        Week = [double]$r.seven_day.utilization; WeekReset = [string]$r.seven_day.resets_at
      }
    } catch { if ($attempt -eq 1) { return $null } }
  }
  return $null
}
# Claude Code sessions that were active since a moment (their transcript was written). Their use would
# mix into a before/after difference. Idle sessions Orca keeps open do not count. The nightly run itself
# leaves no transcript (--no-session-persistence).
function Get-ClaudeActivity([datetime]$since) {
  $base = Join-Path $env:USERPROFILE '.claude\projects'
  if (-not (Test-Path -LiteralPath $base)) { return 0 }
  return @(Get-ChildItem -LiteralPath $base -Recurse -Filter *.jsonl -File -ErrorAction SilentlyContinue |
    Where-Object { $_.LastWriteTime -ge $since -and $_.Directory.Name -ne 'subagents' }).Count
}
# Record one run: log line plus a row in usage-history.csv next to this script.
function Write-PlanUsage($before, [datetime]$startedAt, [string]$daily, $cost, [double]$secs, [scriptblock]$log, [string]$dir) {
  if (-not $before) { & $log 'usage: could not read plan usage before the run (API-key login, no network, or endpoint change)'; return }
  $after = Get-PlanUsage
  if (-not $after) { & $log 'usage: could not read plan usage after the run'; return }
  $notes = @()
  if ([math]::Abs(([datetime]$after.FiveReset - [datetime]$before.FiveReset).TotalMinutes) -gt 5) { $notes += '5시간 창이 바뀜' }
  if ([math]::Abs(([datetime]$after.WeekReset - [datetime]$before.WeekReset).TotalMinutes) -gt 5) { $notes += '주간 창이 바뀜' }
  $active = Get-ClaudeActivity $startedAt
  if ($active -gt 0) { $notes += "다른 Claude 세션 $($active)개가 함께 씀" }
  $d5 = $after.Five - $before.Five; $dw = $after.Week - $before.Week
  $clean = ($notes.Count -eq 0)
  & $log ("usage: 5h {0}% -> {1}% ({2:+0;-0;0}), week {3}% -> {4}% ({5:+0;-0;0}){6}" -f $before.Five, $after.Five, $d5, $before.Week, $after.Week, $dw, $(if ($clean) { '' } else { ' [섞임: ' + ($notes -join ', ') + ']' }))
  $csv = Join-Path $dir 'usage-history.csv'
  if (-not (Test-Path -LiteralPath $csv)) { Add-Content -LiteralPath $csv -Encoding UTF8 -Value 'run_at,daily,cost_usd,secs,five_before,five_after,five_delta,week_before,week_after,week_delta,clean,note' }
  $row = @((Get-Date -Format 'yyyy-MM-dd HH:mm'), $daily, $cost, [math]::Round($secs), $before.Five, $after.Five, $d5, $before.Week, $after.Week, $dw, $clean, ('"' + ($notes -join '; ') + '"')) -join ','
  Add-Content -LiteralPath $csv -Encoding UTF8 -Value $row
}
