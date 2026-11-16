<#
.SYNOPSIS
  Carry out the topic plan the nightly tidy-up wrote: merge overlapping topics and rename topics,
  then fix every link. Claude decides; this script moves the files; Hermes classifies against the result.
.DESCRIPTION
  The tidy-up (gardener-prompt.md 3-8) may write 01_Projects/<project>/.topic-plan.json:
    { "merges":  [ { "from": "<topic>", "into": "<topic>", "reason": "..." } ],
      "renames": [ { "from": "<topic>", "to":   "<name>",  "reason": "..." } ] }
  A rename is a merge into a topic that does not exist yet. For each item:
    - work logs in log/<from>/ move to log/<into>/ (a clashing file name gets " (2)"), and their
      "topic:" line is set to <into>; the capture step finds them again by their session marker;
    - the topic note <from>.md: anything a person wrote outside the auto section moves to the end of
      <into>.md under "## <from>에서 옮긴 메모"; then <from>.md is deleted (a renamed note becomes <into>.md);
    - <into>.md gets "merged_on: <date>" so the next tidy-up rebuilds its flow from all its logs;
    - every [[<from>]] / [[<from>|...]] link in the vault becomes [[<into>...]] (99_Private untouched).
  Topic notes marked "source: human" are never merged or renamed. Every action is appended to
  topic-changes.log (enough to undo by hand). The plan file is removed after it is applied.
  Save as UTF-8 with BOM (PowerShell 5.1).
#>
[CmdletBinding()]
param([string]$VaultPath = '')
$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$KitConfig = $null
try { $KitConfig = Get-Content -LiteralPath (Join-Path $ScriptDir 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
if (-not $VaultPath) { $VaultPath = $(if ($KitConfig -and $KitConfig.vaultPath) { [string]$KitConfig.vaultPath } else { Split-Path -Parent (Split-Path -Parent $ScriptDir) }) }
$LogPath    = Join-Path $ScriptDir 'hermes-inbox.log'
$ChangeLog  = Join-Path $ScriptDir 'topic-changes.log'
$ProjRoot   = Join-Path $VaultPath '01_Projects'
$Utf8       = New-Object System.Text.UTF8Encoding($false)
$Today      = Get-Date -Format 'yyyy-MM-dd'
function Write-Log([string]$m) {
  $line = '{0}  [topics] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
  try { Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 } catch { }
  Write-Output $line
}
function Note-Change([string]$m) { Add-Content -LiteralPath $ChangeLog -Encoding UTF8 -Value ('{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) }
function Read-Utf8([string]$p) { $t = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8); if ($t.Length -gt 0 -and $t[0] -eq [char]0xFEFF) { $t = $t.Substring(1) }; return $t }
function Write-Utf8([string]$p, [string]$t) { [System.IO.File]::WriteAllText($p, $t, $Utf8) }
function Safe-Name([string]$s) { return ($s -replace '[\\/:*?"<>|#^\[\]]', ' ' -replace '\s+', ' ').Trim().TrimEnd('.') }
function Set-FrontLine([string]$text, [string]$key, [string]$value) {
  $m = [regex]::Match($text, '(?s)\A---\r?\n(.*?)\r?\n---')
  if (-not $m.Success) { return $text }
  $fm = $m.Groups[1].Value
  $line = "${key}: $value"
  $fm2 = if ([regex]::IsMatch($fm, "(?m)^${key}:")) { [regex]::Replace($fm, "(?m)^${key}:.*$", $line.Replace('$', '$$')) } else { $fm.TrimEnd() + "`n" + $line }
  return $text.Substring(0, $m.Groups[1].Index) + $fm2 + $text.Substring($m.Groups[1].Index + $m.Groups[1].Length)
}
function Get-HumanPart([string]$text) {
  # What a person wrote: the body minus frontmatter, the H1, the auto section and an empty "관련" line.
  $t = [regex]::Replace($text, '(?s)\A---\r?\n.*?\r?\n---\r?\n?', '')
  $t = [regex]::Replace($t, '(?s)<!-- auto:topic:start -->.*?<!-- auto:topic:end -->', '')
  $t = [regex]::Replace($t, '(?m)^# .*$', '')
  return $t.Trim()
}

$plans = @(Get-ChildItem -LiteralPath $ProjRoot -Recurse -Depth 2 -Filter '.topic-plan.json' -File -Force -ErrorAction SilentlyContinue)
if ($plans.Count -eq 0) { Write-Log 'no topic plan'; exit 0 }

foreach ($pf in $plans) {
  $proj = $pf.DirectoryName
  $projName = $proj.Substring($ProjRoot.Length).TrimStart('\')
  try { $plan = Get-Content -LiteralPath $pf.FullName -Raw -Encoding UTF8 | ConvertFrom-Json } catch { Write-Log "SKIP $projName : plan is not valid JSON"; continue }
  $items = @()
  foreach ($m in @($plan.merges)) { if ($m.from -and $m.into) { $items += [pscustomobject]@{ From = Safe-Name $m.from; Into = Safe-Name $m.into; Kind = 'merge'; Reason = [string]$m.reason } } }
  foreach ($r in @($plan.renames)) { if ($r.from -and $r.to) { $items += [pscustomobject]@{ From = Safe-Name $r.from; Into = Safe-Name $r.to; Kind = 'rename'; Reason = [string]$r.reason } } }
  $done = 0
  # No count limit: the tidy-up only plans changes it is sure of. A plan touching more than half of the
  # project's topics is still applied, but logged as a warning so a person can look.
  $topicCount = @(Get-ChildItem -LiteralPath (Join-Path $proj 'log') -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne '_미분류' }).Count
  if ($topicCount -gt 0 -and $items.Count * 2 -gt $topicCount) { Write-Log ("WARN {0}: the plan changes {1} of {2} topics; check topic-changes.log" -f $projName, $items.Count, $topicCount) }
  foreach ($it in ($items | Select-Object -First 50)) {
    if ($it.From -eq $it.Into -or $it.From -eq '_미분류' -or $it.Into -eq '_미분류') { continue }
    $fromNote = Join-Path $proj ($it.From + '.md'); $intoNote = Join-Path $proj ($it.Into + '.md')
    $fromLog = Join-Path $proj ('log\' + $it.From); $intoLog = Join-Path $proj ('log\' + $it.Into)
    if (-not (Test-Path -LiteralPath $fromNote) -and -not (Test-Path -LiteralPath $fromLog)) { Write-Log "SKIP $projName : no topic '$($it.From)'"; continue }
    if ((Test-Path -LiteralPath $fromNote) -and (Read-Utf8 $fromNote) -match '(?m)^source:\s*human') { Write-Log "SKIP $projName : '$($it.From)' was made by a person"; continue }
    if ((Test-Path -LiteralPath $intoNote) -and (Read-Utf8 $intoNote) -match '(?m)^source:\s*human' -and $it.Kind -eq 'rename') { Write-Log "SKIP $projName : '$($it.Into)' already exists as a person's note"; continue }

    # 1. Work logs.
    $moved = 0
    if (Test-Path -LiteralPath $fromLog) {
      if (-not (Test-Path -LiteralPath $intoLog)) { New-Item -ItemType Directory -Force -Path $intoLog | Out-Null }
      foreach ($f in @(Get-ChildItem -LiteralPath $fromLog -File)) {
        $to = Join-Path $intoLog $f.Name; $n = 2
        while (Test-Path -LiteralPath $to) { $to = Join-Path $intoLog ($f.BaseName + " ($n)" + $f.Extension); $n++ }
        $t = Read-Utf8 $f.FullName
        if ($f.Extension -eq '.md') { $t = Set-FrontLine $t 'topic' ('"' + $it.Into + '"') }
        Write-Utf8 $to $t; Remove-Item -LiteralPath $f.FullName -Force
        Note-Change ("$projName | move log | $($f.FullName) -> $to"); $moved++
      }
      if (-not (Get-ChildItem -LiteralPath $fromLog -Force | Select-Object -First 1)) { Remove-Item -LiteralPath $fromLog -Force }
    }

    # 2. Topic notes.
    if (Test-Path -LiteralPath $fromNote) {
      $fromText = Read-Utf8 $fromNote
      $human = Get-HumanPart $fromText
      if (Test-Path -LiteralPath $intoNote) {
        $t = Read-Utf8 $intoNote
        if ($human -and $human -notmatch '^관련: \[\[[^\]]*\]\]$') { $t = $t.TrimEnd() + "`n`n## $($it.From)에서 옮긴 메모`n" + $human + "`n" }
      } else {
        # Rename: the old note becomes the new one.
        $t = [regex]::Replace($fromText, '(?m)^# .*$', ('# ' + $it.Into).Replace('$', '$$'), 1)
      }
      $t = Set-FrontLine $t 'merged_on' $Today
      $t = Set-FrontLine $t 'updated' $Today
      Write-Utf8 $intoNote $t
      Remove-Item -LiteralPath $fromNote -Force
      Note-Change ("$projName | topic note | $fromNote -> $intoNote (" + $it.Kind + ')')
    }

    # 3. Links everywhere.
    $pat = '\[\[' + [regex]::Escape($it.From) + '(?=[\]|#])'
    $fixed = 0
    $allNotes = @(Get-ChildItem -LiteralPath $VaultPath -Recurse -Filter *.md -File | Where-Object { $_.FullName -notmatch '\\(\.obsidian|99_Private)\\' })   # listed after the moves
    foreach ($n in $allNotes) {
      if (-not (Test-Path -LiteralPath $n.FullName)) { continue }
      $t = Read-Utf8 $n.FullName
      if (-not [regex]::IsMatch($t, $pat)) { continue }
      Write-Utf8 $n.FullName ([regex]::Replace($t, $pat, ('[[' + $it.Into).Replace('$', '$$'))); $fixed++
    }
    Note-Change ("$projName | links | [[$($it.From)]] -> [[$($it.Into)]] in $fixed notes | " + $it.Reason)
    Write-Log ("{0}: {1} '{2}' -> '{3}' (logs {4}, notes with links {5}) | {6}" -f $projName, $it.Kind, $it.From, $it.Into, $moved, $fixed, $it.Reason)
    $done++
  }
  Remove-Item -LiteralPath $pf.FullName -Force
  Note-Change ("$projName | plan applied ($done items) and removed")
}
