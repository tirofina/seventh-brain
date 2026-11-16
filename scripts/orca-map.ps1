<#
.SYNOPSIS
  Save Orca's project list (projects, their folders and worktrees, project groups) to orca-projects.json,
  so the capture step can place every session under the right Orca project, wherever its folder is.
.DESCRIPTION
  Projects and worktrees come from the Orca CLI (orca repo list / orca worktree list --json).
  Group names are not exposed by the CLI; they are read from a copy of Orca's profile database
  (projectGroups entry), never from the live file. When Orca is not running or the CLI fails,
  the previous orca-projects.json is kept, so a 03:00 run with Orca closed still works.
  Output: { "updated": ..., "projects": [ { id, name, group, folder, paths: [ { path, worktree } ] } ] }
  Save as UTF-8 with BOM (PowerShell 5.1).
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$OutFile   = Join-Path $ScriptDir 'orca-projects.json'
$LogPath   = Join-Path $ScriptDir 'hermes-inbox.log'
function Write-Log([string]$m) {
  $line = '{0}  [orca] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
  try { Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 } catch { }
  Write-Output $line
}
function Norm([string]$p) { return ([string]$p -replace '/', '\').TrimEnd('\') }
function Invoke-Orca([string[]]$a) {
  $exe = Get-Command orca -CommandType Application -All -ErrorAction SilentlyContinue | Where-Object { $_.Source -match '\.(cmd|exe|bat)$' } | Sort-Object { if ($_.Source -match '\.exe$') { 0 } else { 1 } } | Select-Object -First 1
  if (-not $exe) { throw 'orca CLI not found' }
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $(if ($exe.Source -match '\.(cmd|bat)$') { Join-Path $env:SystemRoot 'System32\cmd.exe' } else { $exe.Source })
  $psi.Arguments = $(if ($exe.Source -match '\.(cmd|bat)$') { '/d /s /c ""' + $exe.Source + '" ' + ($a -join ' ') + '"' } else { $a -join ' ' })
  $psi.UseShellExecute = $false; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
  $p = [System.Diagnostics.Process]::Start($psi)
  $out = $p.StandardOutput.ReadToEndAsync()
  if (-not $p.WaitForExit(60000)) { try { $p.Kill() } catch { }; throw 'orca CLI timed out' }
  $j = $out.Result | ConvertFrom-Json
  if (-not $j.ok) { throw ('orca CLI error: ' + ($out.Result -replace '\s+', ' ').Substring(0, [Math]::Min(200, $out.Result.Length))) }
  return $j.result
}

try {
  $repos = @((Invoke-Orca @('repo', 'list', '--json')).repos)
  $wts   = @((Invoke-Orca @('worktree', 'list', '--json')).worktrees)
} catch {
  if (Test-Path -LiteralPath $OutFile) { Write-Log ("Orca list unavailable ({0}); keeping the previous orca-projects.json" -f $_.Exception.Message) }
  else { Write-Log ("Orca list unavailable ({0}); capture falls back to the orcaRoot folder rule" -f $_.Exception.Message) }
  exit 0
}

# Group names: read from a copy of the profile database (the CLI does not list them).
$groups = @{}
try {
  $profileId = 'local-default'
  $idx = Join-Path $env:APPDATA 'orca\orca-profile-index.json'
  if (Test-Path -LiteralPath $idx) { $pi = Get-Content -LiteralPath $idx -Raw -Encoding UTF8 | ConvertFrom-Json; if ($pi.activeProfileId) { $profileId = [string]$pi.activeProfileId } }
  $db = Join-Path $env:APPDATA ("orca\profiles\$profileId\profile-state.db")
  if (Test-Path -LiteralPath $db) {
    $tmp = Join-Path $env:TEMP ('orca-profile-' + [guid]::NewGuid().ToString('N') + '.db')
    Copy-Item -LiteralPath $db -Destination $tmp
    try {
      $text = [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($tmp))
      foreach ($m in [regex]::Matches($text, '\{"id":"([0-9a-f-]{36})","name":"([^"]+)","parentPath"')) { $groups[$m.Groups[1].Value] = $m.Groups[2].Value }
    } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
  }
} catch { Write-Log ('group names unavailable: ' + $_.Exception.Message) }

$projects = foreach ($r in $repos) {
  $paths = New-Object System.Collections.Generic.List[object]
  $paths.Add([ordered]@{ path = (Norm $r.path); worktree = '메인' })
  foreach ($w in @($wts | Where-Object { $_.repoId -eq $r.id })) {
    $wp = Norm $w.path
    if ($wp -ieq (Norm $r.path)) { continue }   # main checkout, or a folder workspace sharing the same folder
    $paths.Add([ordered]@{ path = $wp; worktree = [string]$w.displayName })
  }
  $g = if ($r.projectGroupId -and $groups.ContainsKey([string]$r.projectGroupId)) { $groups[[string]$r.projectGroupId] } else { '' }
  [ordered]@{ id = [string]$r.id; name = [string]$r.displayName; group = $g; folder = (Split-Path -Leaf (Norm $r.path)); paths = $paths }
}
$doc = [ordered]@{ updated = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'); projects = @($projects) }
[System.IO.File]::WriteAllText($OutFile, ($doc | ConvertTo-Json -Depth 6), (New-Object System.Text.UTF8Encoding($false)))
Write-Log ("saved {0} projects: {1}" -f @($projects).Count, ((@($projects) | ForEach-Object { if ($_.group) { $_.group + '/' + $_.name } else { $_.name } }) -join ', '))
