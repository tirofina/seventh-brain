<#
.SYNOPSIS
  Convert recent Codex session files that ran inside Orca into the transcript shape that
  capture-sessions.ps1 reads, so Codex work is captured exactly like Claude Code work.
.DESCRIPTION
  Codex writes <CODEX_HOME>/sessions/YYYY/MM/DD/rollout-<time>-<id>.jsonl. The first line
  (type session_meta) holds the working directory in payload.cwd; conversation turns are
  response_item lines whose payload.type is "message" with role user or assistant and content
  items of type input_text / output_text. Developer messages, tool calls, reasoning and the
  context Codex injects into user turns (AGENTS.md text, <environment_context> and similar
  tagged blocks) are dropped.
  Output: <this folder>/codex-transcripts/<working-dir key>/<session id>.jsonl, one line per
  turn: {"type":"user"|"assistant","cwd":...,"message":{"role":...,"content":[{"type":"text",...}]}}.
  The key is built like Claude Code's project folder names, so the dirFilter in config.json
  matches. Each output file gets the source file's modification time, so the capture step's
  state file re-summarizes only sessions that changed. Only sessions under orcaRoot are kept.
  Save as UTF-8 with BOM (PowerShell 5.1).
#>
[CmdletBinding()]
param(
  [string]$OrcaRoot = '',
  [string]$CodexHome = $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }),
  [int]$SinceHours = 168
)

$ErrorActionPreference = 'Stop'
# Settings written by install.ps1 (read here: param defaults cannot see the script folder in PowerShell 5.1).
$KitConfig = $null
try { $KitConfig = Get-Content -LiteralPath (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
if ($KitConfig) {
  if (-not $OrcaRoot) { $OrcaRoot = [string]$KitConfig.orcaRoot }
}
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$OutRoot   = Join-Path $ScriptDir 'codex-transcripts'
$LogPath   = Join-Path $ScriptDir 'hermes-inbox.log'
$Utf8      = New-Object System.Text.UTF8Encoding($false)

function Write-Log([string]$msg) {
  $line = '{0}  [codex] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
  try { Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 } catch { }
  Write-Output $line
}
function To-Key([string]$p) { return ([System.IO.Path]::GetFullPath($p).TrimEnd('\') -replace '[^A-Za-z0-9]', '-') }
# Text Codex adds to user turns on its own, not typed by the person.
function Is-Injected([string]$t) {
  $s = $t.TrimStart()
  return ($s -eq '' -or $s.StartsWith('<') -or $s.StartsWith('# AGENTS.md instructions'))
}

$sessions = Join-Path $CodexHome 'sessions'
if (-not (Test-Path -LiteralPath $sessions)) { Write-Log "No Codex sessions folder ($sessions). Nothing to convert."; exit 0 }
$root = [System.IO.Path]::GetFullPath($OrcaRoot).TrimEnd('\') + '\'
$cutoff = (Get-Date).AddHours(-$SinceHours)
$done = 0; $skipped = 0
foreach ($f in @(Get-ChildItem -LiteralPath $sessions -Recurse -Filter 'rollout-*.jsonl' -File | Where-Object { $_.LastWriteTime -ge $cutoff })) {
  try {
    $reader = New-Object System.IO.StreamReader($f.FullName, [System.Text.Encoding]::UTF8)
    $meta = $null
    try { $meta = $reader.ReadLine() | ConvertFrom-Json } finally { $reader.Close() }
    if ($null -eq $meta -or $meta.type -ne 'session_meta') { $skipped++; continue }
    $cwd = [string]$meta.payload.cwd
    if (-not $cwd -or -not ($cwd.TrimEnd('\') + '\').StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) { $skipped++; continue }
    $sid = [string]$meta.payload.id
    if (-not $sid) { $sid = [string]$meta.payload.session_id }
    if (-not $sid) { $sid = $f.BaseName }
    $outDir = Join-Path $OutRoot (To-Key $cwd)
    $out = Join-Path $outDir ($sid + '.jsonl')
    if ((Test-Path -LiteralPath $out) -and (Get-Item -LiteralPath $out).LastWriteTime -ge $f.LastWriteTime) { $skipped++; continue }

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($l in [System.IO.File]::ReadLines($f.FullName, [System.Text.Encoding]::UTF8)) {
      if ($l -notmatch '"type"\s*:\s*"message"' -or $l -notmatch '"role"\s*:\s*"(user|assistant)"') { continue }
      $o = $null
      try { $o = $l | ConvertFrom-Json } catch { continue }
      if ($o.type -ne 'response_item' -or $o.payload.type -ne 'message') { continue }
      $role = [string]$o.payload.role
      if ($role -ne 'user' -and $role -ne 'assistant') { continue }
      $texts = @(@($o.payload.content) | Where-Object { $_.type -in 'input_text', 'output_text', 'text' -and $_.text } | ForEach-Object { [string]$_.text })
      if ($role -eq 'user') { $texts = @($texts | Where-Object { -not (Is-Injected $_) }) }
      $text = ($texts -join "`n").Trim()
      if ($text -eq '') { continue }
      $rec = [ordered]@{ type = $role; cwd = $cwd; message = [ordered]@{ role = $role; content = @([ordered]@{ type = 'text'; text = $text }) } }
      $lines.Add(($rec | ConvertTo-Json -Depth 6 -Compress))
    }
    if ($lines.Count -eq 0) { $skipped++; continue }
    if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
    [System.IO.File]::WriteAllText($out, (($lines -join "`n") + "`n"), $Utf8)
    (Get-Item -LiteralPath $out).LastWriteTime = $f.LastWriteTime
    $done++
    Write-Log ("OK   session {0} ({1} turns) from {2}" -f $sid.Substring(0, [Math]::Min(8, $sid.Length)), $lines.Count, $cwd)
  } catch { Write-Log ("FAIL {0}: {1}" -f $f.Name, $_.Exception.Message) }
}
Write-Log ("Done. converted=$done skipped=$skipped")
