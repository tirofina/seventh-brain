<#
.SYNOPSIS
  Copy the vault's work-preference note (02_Notes/작업-선호.md) into the agents' global instructions.
.DESCRIPTION
  Codex has no import syntax, so the note's body is copied into a managed block of
  <CODEX_HOME>/AGENTS.md every night. Claude Code imports the note directly with an @path line,
  except when the vault path contains a space (the import cannot handle it); then config.json has
  syncPrefsToClaude = true and the body is also copied into ~/.claude/CLAUDE.md.
  Only the block between the markers is replaced; the rest of each file is left as it is.
  Save as UTF-8 with BOM (PowerShell 5.1).
#>
[CmdletBinding()]
param(
  [string]$VaultPath = '',
  [string]$CodexHome = $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }),
  [string]$ClaudeHome = (Join-Path $env:USERPROFILE '.claude'),
  [switch]$AlsoClaude
)
$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$KitConfig = $null
try { $KitConfig = Get-Content -LiteralPath (Join-Path $ScriptDir 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
if ($KitConfig) {
  if (-not $VaultPath) { $VaultPath = [string]$KitConfig.vaultPath }
  if ($KitConfig.syncPrefsToClaude) { $AlsoClaude = $true }
}
if (-not $VaultPath) { $VaultPath = Split-Path -Parent (Split-Path -Parent $ScriptDir) }   # <vault>\90_Meta\scripts
$LogPath = Join-Path $ScriptDir 'hermes-inbox.log'
function Write-Log([string]$m) {
  $line = '{0}  [prefs] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
  try { Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 } catch { }
  Write-Output $line
}
$note = Join-Path $VaultPath '02_Notes\작업-선호.md'
if (-not (Test-Path -LiteralPath $note)) { Write-Log 'No 02_Notes/작업-선호.md. Nothing to sync.'; exit 0 }

$t = [System.IO.File]::ReadAllText($note, [System.Text.Encoding]::UTF8)
if ($t.Length -gt 0 -and $t[0] -eq [char]0xFEFF) { $t = $t.Substring(1) }
$t = [regex]::Replace($t, '(?s)\A---\r?\n.*?\r?\n---\r?\n', '')           # frontmatter
$t = [regex]::Replace($t, '(?m)^<!-- auto:prefs:(start|end) -->\r?\n?', '') # inner markers
$start = '<!-- seventh-brain-prefs:start (02_Notes/작업-선호.md 에서 밤마다 복사된다. 여기서 고치지 말고 그 노트를 고친다) -->'
$end   = '<!-- seventh-brain-prefs:end -->'
$block = $start + "`r`n" + $t.Trim() + "`r`n" + $end

function Set-Block([string]$file) {
  $enc = New-Object System.Text.UTF8Encoding($false)
  $old = if (Test-Path -LiteralPath $file) { [System.IO.File]::ReadAllText($file, [System.Text.Encoding]::UTF8) } else { '' }
  if ($old.Length -gt 0 -and $old[0] -eq [char]0xFEFF) { $old = $old.Substring(1) }
  $i = $old.IndexOf('<!-- seventh-brain-prefs:start'); $j = $old.IndexOf($end)
  $new = if ($i -ge 0 -and $j -gt $i) { $old.Substring(0, $i) + $block + $old.Substring($j + $end.Length) }
         elseif ($old.Trim() -eq '') { $block + "`r`n" }
         else { $old.TrimEnd() + "`r`n`r`n" + $block + "`r`n" }
  if ($new -ne $old) {
    $d = Split-Path -Parent $file
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    [System.IO.File]::WriteAllText($file, $new, $enc)
    Write-Log ('updated ' + $file)
  } else { Write-Log ('unchanged ' + $file) }
}
if (Test-Path -LiteralPath $CodexHome) { Set-Block (Join-Path $CodexHome 'AGENTS.md') }
if ($AlsoClaude) { Set-Block (Join-Path $ClaudeHome 'CLAUDE.md') }
