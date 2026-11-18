<#
.SYNOPSIS
  Keep the project folders of 01_Projects (and 04_References) in the shape of Orca's project tree.
.DESCRIPTION
  Orca is the source of truth for projects and groups (orca-projects.json from orca-map.ps1).
  For each Orca project the script finds its vault folders: folders whose first page (_index.md)
  has the project's id in "orca:" or "orca_ids:", and, among first pages no current Orca project
  claims by id, the same "orca_path:" or the project name as title, folder name or tag. Then:
    merge   several folders for one project (Orca gives a project a new id when it is removed and
            added again, so the capture step used to start a second folder): everything moves into
            one folder, the keeper (the folder that is the Orca project's own path, else the oldest
            first page). Work logs, decisions, topic notes and the 04_References folder move; a
            clashing log or decision gets " (2)", a clashing reference note gets " 2" (the reference
            DB follows), a clashing topic note gets the other one's body appended. The first pages
            are combined: decision lines, the topic and recent lists, any other section.
    relink  the kept first page gets the current id in "orca:", every id it had in "orca_ids:" and
            the current "orca_path:", so the capture and reference steps find it by id again.
    move    the folder is not at 01_Projects/<group>/<project>: it moves there with its
            04_References folder. A move is applied only when it was already planned at least
            MoveDelayHours earlier, so a half-finished change in Orca is not followed at once.
            A folder that is an Orca project's own path never moves, and a group whose name could
            not be read leaves its projects where they are.
  Links written with a path ([[folder/note]]) to a moved file are rewritten in the whole vault
  except 99_Private. Every changed or removed file is first copied into
  90_Meta/backups/tree-<time>.zip, and every action is appended to topic-changes.log.
  Without -Apply the plan is only printed. With more than MaxOps merges and moves, only the
  relinks are applied and the rest waits for a person.
  Save as UTF-8 with BOM (PowerShell 5.1).
#>
[CmdletBinding()]
param(
  [switch]$Apply,
  [string]$VaultPath = '',
  [int]$MoveDelayHours = 20,
  [int]$MaxOps = 5
)
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
# Settings written by install.ps1 (read here: param defaults cannot see the script folder in PowerShell 5.1).
# Orca itself is read from orca-projects.json (orca-map.ps1), so orcaRoot is not needed here.
$KitConfig = $null
try { $KitConfig = Get-Content -LiteralPath (Join-Path $ScriptDir 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
if ($KitConfig) {
  if (-not $VaultPath) { $VaultPath = [string]$KitConfig.vaultPath }
}
# This script moves folders, so it stops instead of guessing the vault.
if (-not $VaultPath -or -not (Test-Path -LiteralPath $VaultPath)) { throw 'config.json is missing or vaultPath is wrong. Run install.ps1 first.' }
$VaultPath = $VaultPath.TrimEnd('\')
$LogPath   = Join-Path $ScriptDir 'hermes-inbox.log'
$ChangeLog = Join-Path $ScriptDir 'topic-changes.log'
$MapFile   = Join-Path $ScriptDir 'orca-projects.json'
$StateFile = Join-Path $ScriptDir 'tree-state.json'
$DbFile    = Join-Path $ScriptDir 'references-db.json'
$ProjRoot  = Join-Path $VaultPath '01_Projects'
$RefRoot   = Join-Path $VaultPath '04_References'
$BackupDir = Join-Path $VaultPath '90_Meta\backups'
$Utf8      = New-Object System.Text.UTF8Encoding($false)
$Now       = Get-Date
$Today     = $Now.ToString('yyyy-MM-dd')

function Write-Log([string]$m) {
  $line = '{0}  [tree] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
  if ($Apply) { try { Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 } catch { } }
  Write-Host $line
}
function Note-Change([string]$m) { Add-Content -LiteralPath $ChangeLog -Encoding UTF8 -Value ('{0}  tree | {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) }
function Read-Utf8([string]$p) { $t = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8); if ($t.Length -gt 0 -and $t[0] -eq [char]0xFEFF) { $t = $t.Substring(1) }; return $t }
function Write-Utf8([string]$p, [string]$t) { [System.IO.File]::WriteAllText($p, $t, $Utf8) }
function Safe-Name([string]$s, [int]$max = 60) {
  $s = ($s -replace '[\\/:*?"<>|#^\[\]]', ' ' -replace '\s+', ' ').Trim().TrimEnd('.')
  if ($s.Length -gt $max) { $s = $s.Substring(0, $max).Trim() }
  return $s
}
function Norm([string]$p) { return ([string]$p -replace '/', '\').TrimEnd('\') }
function Rel([string]$full, [string]$root) { return $full.Substring($root.Length).TrimStart('\') }
function Get-Frontmatter([string]$t) { return ([regex]::Match($t, '(?s)\A---\r?\n(.*?)\r?\n---')).Groups[1].Value }
function Fm-Value([string]$fm, [string]$key) { return ([regex]::Match($fm, '(?m)^' + [regex]::Escape($key) + ':[ \t]*"?([^"\r\n]*?)"?[ \t]*$')).Groups[1].Value }
function Fm-List([string]$fm, [string]$key) {
  $m = [regex]::Match($fm, '(?m)^' + [regex]::Escape($key) + ':[ \t]*\[(.*)\]')
  if ($m.Success) { return @($m.Groups[1].Value -split ',' | ForEach-Object { $_.Trim().Trim('"').Trim("'") } | Where-Object { $_ }) }
  $m = [regex]::Match($fm, '(?m)^' + [regex]::Escape($key) + ':[ \t]*\r?\n((?:[ \t]+-[^\r\n]*\r?\n?)+)')
  if ($m.Success) { return @($m.Groups[1].Value -split '\r?\n' | ForEach-Object { ($_ -replace '^\s*-\s*', '').Trim().Trim('"').Trim("'") } | Where-Object { $_ }) }
  return @()
}
function Set-Fm([string]$text, [string]$key, [string]$line, [string]$after = '') {
  # Put "$line" in place of the frontmatter key, or add it after the $after key (else at the end).
  $m = [regex]::Match($text, '(?s)\A---\r?\n(.*?)\r?\n---')
  if (-not $m.Success) { return "---`n$line`n---`n`n" + $text }
  $fm = $m.Groups[1].Value -replace '\r\n', "`n"
  $re = '(?m)^' + [regex]::Escape($key) + ':.*$'
  if ([regex]::IsMatch($fm, $re)) { $fm = [regex]::Replace($fm, $re, $line.Replace('$', '$$')) }
  elseif ($after -and [regex]::IsMatch($fm, '(?m)^' + [regex]::Escape($after) + ':.*$')) { $fm = [regex]::Replace($fm, '(?m)^(' + [regex]::Escape($after) + ':.*)$', ('$1' + "`n" + $line.Replace('$', '$$'))) }
  else { $fm = $fm.TrimEnd() + "`n" + $line }
  return "---`n" + $fm + "`n---" + $text.Substring($m.Length)
}
function Link-Key([string]$line) {
  # The first [[link]] target of a list line; the whole line when it has none.
  $m = [regex]::Match($line, '\[\[([^\]|#]+)')
  if ($m.Success) { return $m.Groups[1].Value.Trim() } else { return $line.Trim() }
}

# ---- Backup, moves, removals ----
$Stage = Join-Path $env:TEMP ('tree-backup-' + [guid]::NewGuid().ToString('N'))
$BackedUp = @{}
$Moved = [ordered]@{}   # old full path -> new full path (also "merged into")
function Backup-File([string]$full) {
  if ($BackedUp.ContainsKey($full) -or -not (Test-Path -LiteralPath $full)) { return }
  $dst = Join-Path $Stage (Rel $full $VaultPath)
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
  Copy-Item -LiteralPath $full -Destination $dst
  $BackedUp[$full] = $true
}
function Add-Moved([string]$old, [string]$new) {
  foreach ($k in @($Moved.Keys)) { if ($Moved[$k] -ieq $old) { $Moved[$k] = $new } }
  $Moved[$old] = $new
}
function Unique-Path([string]$path, [string]$style) {
  if (-not (Test-Path -LiteralPath $path)) { return $path }
  $dir = Split-Path -Parent $path; $base = [System.IO.Path]::GetFileNameWithoutExtension($path); $ext = [System.IO.Path]::GetExtension($path)
  $n = 2
  while ($true) {
    $cand = Join-Path $dir ($(if ($style -eq 'space') { "$base $n" } else { "$base ($n)" }) + $ext)
    if (-not (Test-Path -LiteralPath $cand)) { return $cand }
    $n++
  }
}
function Move-OneFile([string]$src, [string]$dst) {
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dst) | Out-Null
  Move-Item -LiteralPath $src -Destination $dst
  Add-Moved $src $dst
  Note-Change ('move | {0} -> {1}' -f (Rel $src $VaultPath), (Rel $dst $VaultPath))
}
function Remove-OneFile([string]$src, [string]$into, [string]$why) {
  Backup-File $src
  Remove-Item -LiteralPath $src -Force
  Add-Moved $src $into
  Note-Change ('merge | {0} -> {1} ({2})' -f (Rel $src $VaultPath), (Rel $into $VaultPath), $why)
}
function Same-File([string]$a, [string]$b) { return ((Get-FileHash -LiteralPath $a).Hash -eq (Get-FileHash -LiteralPath $b).Hash) }
function Remove-EmptyDirs([string]$dir, [string]$stopAt) {
  if (-not (Test-Path -LiteralPath $dir)) { return }
  foreach ($d in @(Get-ChildItem -LiteralPath $dir -Recurse -Directory -Force | Sort-Object { $_.FullName.Length } -Descending)) {
    if (-not @(Get-ChildItem -LiteralPath $d.FullName -Force)) { Remove-Item -LiteralPath $d.FullName -Force }
  }
  $cur = $dir
  while ($cur -and ($cur -ine $stopAt) -and $cur.StartsWith($stopAt + '\', [System.StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $cur) -and -not @(Get-ChildItem -LiteralPath $cur -Force)) {
    Remove-Item -LiteralPath $cur -Force
    $cur = Split-Path -Parent $cur
  }
  if (Test-Path -LiteralPath $dir) { Write-Log ('     left in place (not empty): ' + (Rel $dir $VaultPath)) }
}

# ---- Merging one folder into another ----
function Append-Body([string]$src, [string]$into, [string]$fromLabel) {
  # A clashing topic note: the other note's body goes to the end of the kept one.
  $t = Read-Utf8 $src
  $body = $t.Substring(([regex]::Match($t, '(?s)\A---\r?\n.*?\r?\n---\r?\n?')).Length).Trim()
  Backup-File $into
  $k = Read-Utf8 $into
  if ($body -and -not $k.Contains($body)) {
    $k = $k.TrimEnd() + "`n`n## " + $fromLabel + "에서 옮긴 내용`n`n" + $body + "`n"
    $k = Set-Fm $k 'merged_on' ('merged_on: ' + $Today)
    Write-Utf8 $into $k
  }
  Remove-OneFile $src $into 'topic note appended'
}
function Human-Tail([string]$t) {
  # What a person wrote below a generated reference note's auto section.
  $j = $t.LastIndexOf('<!-- auto:ref:end -->')
  if ($j -lt 0) { return '' }
  return ([regex]::Replace($t.Substring($j + '<!-- auto:ref:end -->'.Length), '(?m)^##\s*메모\s*$', '')).Trim()
}
function Merge-Dir([string]$from, [string]$into, [string]$kind, [string]$fromLabel) {
  # kind 'project': 01_Projects folder (the first page is merged separately); kind 'ref': 04_References folder.
  if (-not (Test-Path -LiteralPath $from)) { return }
  $fromLeaf = Split-Path -Leaf $from; $intoLeaf = Split-Path -Leaf $into
  foreach ($f in @(Get-ChildItem -LiteralPath $from -Recurse -File -Force)) {
    $rel = Rel $f.FullName $from
    if ($kind -eq 'project' -and $rel -ieq '_index.md' -and (Test-Path -LiteralPath (Join-Path $into '_index.md'))) { continue }
    $dst = Join-Path $into $rel
    if ($kind -eq 'ref' -and $rel -ieq ($fromLeaf + ' 참고 자료.md')) { $dst = Join-Path $into ($intoLeaf + ' 참고 자료.md') }
    if (-not (Test-Path -LiteralPath $dst)) { Move-OneFile $f.FullName $dst; continue }
    if (Same-File $f.FullName $dst) { Remove-OneFile $f.FullName $dst 'same content'; continue }
    if ($kind -eq 'ref') {
      $st = Read-Utf8 $f.FullName; $dt = Read-Utf8 $dst
      $sk = Fm-Value (Get-Frontmatter $st) 'ref-key'; $dk = Fm-Value (Get-Frontmatter $dt) 'ref-key'
      $isIndex = ($rel -ieq ($fromLeaf + ' 참고 자료.md'))
      if ($isIndex -or ($sk -and $sk -eq $dk)) {
        $tail = Human-Tail $st
        if ($tail -and -not $dt.Contains($tail)) { Backup-File $dst; Write-Utf8 $dst ($dt.TrimEnd() + "`n`n" + $tail + "`n") }
        Remove-OneFile $f.FullName $dst 'reference note merged'
      } else { Move-OneFile $f.FullName (Unique-Path $dst 'space') }
      continue
    }
    $isRootNote = ($rel -notmatch '\\') -and ($rel -match '\.md$')
    $human = ((Fm-Value (Get-Frontmatter (Read-Utf8 $f.FullName)) 'source') -eq 'human') -or ((Fm-Value (Get-Frontmatter (Read-Utf8 $dst)) 'source') -eq 'human')
    if ($isRootNote -and -not $human) { Append-Body $f.FullName $dst $fromLabel }
    else { Move-OneFile $f.FullName (Unique-Path $dst 'paren') }
  }
}
function Merge-Hub([string]$fromFile, [string]$intoFile, [string]$fromLabel) {
  $f = Read-Utf8 $fromFile; $k = Read-Utf8 $intoFile
  Backup-File $intoFile
  # Tags: union.
  $tags = @(@(Fm-List (Get-Frontmatter $k) 'tags') + @(Fm-List (Get-Frontmatter $f) 'tags') | Select-Object -Unique)
  if ($tags.Count) { $k = Set-Fm $k 'tags' ('tags: [' + ($tags -join ', ') + ']') }
  # Decision lines.
  $re = '(?ms)^## 결정 기록[ \t]*\r?\n(.*?)(?=^## |\z)'
  $fd = [regex]::Match($f, $re); $kd = [regex]::Match($k, $re)
  if ($fd.Success) {
    $have = @{}; $lines = New-Object System.Collections.Generic.List[string]
    if ($kd.Success) { foreach ($l in @($kd.Groups[1].Value -split '\r?\n' | Where-Object { $_.Trim() })) { $lines.Add($l); $have[(Link-Key $l)] = $true } }
    foreach ($l in @($fd.Groups[1].Value -split '\r?\n' | Where-Object { $_ -match '^\s*-\s' })) { if (-not $have.ContainsKey((Link-Key $l))) { $lines.Add($l); $have[(Link-Key $l)] = $true } }
    $sec = "## 결정 기록`n" + $(if ($lines.Count) { ($lines -join "`n") + "`n" } else { '' }) + "`n"
    if ($kd.Success) { $k = $k.Substring(0, $kd.Index) + $sec + $k.Substring($kd.Index + $kd.Length) } elseif ($lines.Count) { $k = $k.TrimEnd() + "`n`n" + $sec }
  }
  # Auto lists (the reference list is rebuilt by collect-references.ps1).
  foreach ($name in 'topics', 'recent') {
    $bre = '(?s)<!-- auto:' + $name + ':start -->(.*?)<!-- auto:' + $name + ':end -->'
    $fm_ = [regex]::Match($f, $bre); $km = [regex]::Match($k, $bre)
    if (-not $fm_.Success -or -not $km.Success) { continue }
    $have = @{}; $lines = New-Object System.Collections.Generic.List[string]
    foreach ($l in @($km.Groups[1].Value -split '\r?\n' | Where-Object { $_.Trim() })) { $lines.Add($l); $have[$l.Trim()] = $true }
    foreach ($l in @($fm_.Groups[1].Value -split '\r?\n' | Where-Object { $_.Trim() })) {
      if ($have.ContainsKey($l.Trim())) { continue }
      if ($name -eq 'topics' -and @($lines | Where-Object { (Link-Key $_) -eq (Link-Key $l) }).Count) { continue }
      $lines.Add($l); $have[$l.Trim()] = $true
    }
    $out = @($lines)
    if ($name -eq 'recent') { $out = @($lines | Sort-Object { Link-Key $_ } -Descending) }
    $block = '<!-- auto:' + $name + ':start -->' + "`n" + $(if ($out.Count) { ($out -join "`n") + "`n" } else { '' }) + '<!-- auto:' + $name + ':end -->'
    $k = $k.Substring(0, $km.Index) + $block + $k.Substring($km.Index + $km.Length)
  }
  # Anything else a person wrote on the other first page.
  $body = $f.Substring(([regex]::Match($f, '(?s)\A---\r?\n.*?\r?\n---\r?\n?')).Length)
  $known = '^(결정 기록|주제 \(자동 갱신\)|최근 진행 \(자동 갱신\)|참고 자료 \(자동 갱신\))\s*$'
  $extra = New-Object System.Collections.Generic.List[string]
  foreach ($part in @([regex]::Split($body, '(?m)^(?=## )'))) {
    $p = $part.Trim()
    if (-not $p) { continue }
    if ($p.StartsWith('## ')) {
      $head = ($p -split '\r?\n')[0].Substring(3).Trim()
      if ($head -match $known) { continue }
      if (-not $k.Contains($p)) { $extra.Add($p) }
    } else {
      # Skip the title and the generated intro line (capture-sessions.ps1 and install.ps1 word it slightly differently).
      $pre = @($p -split '\r?\n' | Where-Object { $_.Trim() -and $_ -notmatch '^#\s' -and $_ -notmatch '^Orca 프로젝트 .+의 첫 페이지(다)?\.' }) -join "`n"
      if ($pre.Trim() -and -not $k.Contains($pre.Trim())) { $extra.Add($pre.Trim()) }
    }
  }
  if ($extra.Count) { $k = $k.TrimEnd() + "`n`n## " + $fromLabel + "에서 옮긴 메모`n`n" + (($extra | ForEach-Object { $_ -replace '(?m)^## ', '### ' }) -join "`n`n") + "`n" }
  Write-Utf8 $intoFile $k
  Remove-OneFile $fromFile $intoFile 'first pages combined'
}
function Set-Identity([string]$hubFile, [string]$projId, [string[]]$ids, [string]$path) {
  $t = Read-Utf8 $hubFile; $orig = $t
  $t = Set-Fm $t 'orca' ('orca: "' + $projId + '"') 'tags'
  if (@($ids).Count -gt 1) { $t = Set-Fm $t 'orca_ids' ('orca_ids: [' + ((@($ids) | ForEach-Object { '"' + $_ + '"' }) -join ', ') + ']') 'orca' }
  if ($path) { $t = Set-Fm $t 'orca_path' ('orca_path: "' + ($path -replace '\\', '/') + '"') 'orca' }
  if ($t -ne $orig) {
    $t = Set-Fm $t 'updated' ('updated: ' + $Today)
    Backup-File $hubFile; Write-Utf8 $hubFile $t
    Note-Change ('relink | {0} -> orca {1}' -f (Rel $hubFile $VaultPath), $projId)
  }
}

# ---- What Orca says and what the vault has ----
if (-not (Test-Path -LiteralPath $MapFile)) { Write-Log 'orca-projects.json missing; nothing to compare'; exit 0 }
$OrcaProjects = @((Get-Content -LiteralPath $MapFile -Raw -Encoding UTF8 | ConvertFrom-Json).projects)
if ($OrcaProjects.Count -eq 0) { Write-Log 'Orca lists no projects; nothing to compare'; exit 0 }
function Get-Hubs {
  $list = @()
  if (-not (Test-Path -LiteralPath $ProjRoot)) { return $list }
  foreach ($h in @(Get-ChildItem -LiteralPath $ProjRoot -Recurse -Depth 2 -Filter '_index.md' -File)) {
    $dir = $h.DirectoryName
    if ($dir -ieq $ProjRoot) { continue }
    $rel = Rel $dir $ProjRoot
    if (@($rel.Split('\') | Where-Object { $_ -in 'log', 'decisions', 'specs' }).Count) { continue }
    $t = Read-Utf8 $h.FullName; $fm = Get-Frontmatter $t
    $orca = Fm-Value $fm 'orca'
    $list += [pscustomobject]@{
      Dir = $dir; Rel = $rel; File = $h.FullName; Orca = $orca
      Ids = @(@($orca) + @(Fm-List $fm 'orca_ids') | Where-Object { $_ } | Select-Object -Unique)
      Path = (Norm (Fm-Value $fm 'orca_path')); Title = ([regex]::Match($t, '(?m)^#\s+(.+?)\s*$')).Groups[1].Value
      Leaf = (Split-Path -Leaf $dir); Tags = @(Fm-List $fm 'tags'); Created = (Fm-Value $fm 'created')
      Files = @(Get-ChildItem -LiteralPath $dir -Recurse -File -Force).Count
    }
  }
  return $list
}
$hubs = @(Get-Hubs)
$claimed = @{}   # first page -> Orca project id
foreach ($p in $OrcaProjects) { foreach ($h in $hubs) { if ($h.Ids -contains [string]$p.id) { $claimed[$h.File] = [string]$p.id } } }

$plan = New-Object System.Collections.Generic.List[object]
foreach ($p in $OrcaProjects) {
  $projId = [string]$p.id; $pname = [string]$p.name
  $ppath = Norm ([string]@($p.paths)[0].path)
  $byId = @($hubs | Where-Object { $claimed[$_.File] -eq $projId })
  $byOther = @($hubs | Where-Object { -not $claimed.ContainsKey($_.File) -and (
      ($_.Path -and $ppath -and $_.Path -ieq $ppath) -or ($_.Title -and $_.Title -ieq $pname) -or ($_.Leaf -ieq (Safe-Name $pname)) -or
      ($_.Tags -contains $pname) -or ($p.folder -and $_.Tags -contains [string]$p.folder)) })
  foreach ($h in $byOther) { $claimed[$h.File] = $projId }
  $found = @($byId) + @($byOther)
  if ($found.Count -eq 0) { continue }
  $pinned = @($found | Where-Object { $ppath -and ($ppath -ieq $_.Dir -or $ppath.StartsWith($_.Dir + '\', [System.StringComparison]::OrdinalIgnoreCase)) }) | Select-Object -First 1
  $keeper = $(if ($pinned) { $pinned } else { @($found | Sort-Object @{ Expression = { if ($_.Created) { $_.Created } else { '9999' } } }, @{ Expression = { $_.Files }; Descending = $true }) | Select-Object -First 1 })
  foreach ($h in $found) { if ($h.File -ne $keeper.File) { $plan.Add([pscustomobject]@{ Kind = 'merge'; Proj = $p; From = $h; Into = $keeper }) } }
  $ids = @(@($found | ForEach-Object { $_.Ids }) + @($projId) | Where-Object { $_ } | Select-Object -Unique)
  if ($keeper.Orca -ne $projId -or ($ppath -and $keeper.Path -ine $ppath) -or ($ids.Count -gt 1 -and @($keeper.Ids).Count -lt $ids.Count)) {
    $plan.Add([pscustomobject]@{ Kind = 'relink'; Proj = $p; Hub = $keeper; Ids = $ids; Path = $ppath })
  }
  $groupUnknown = ([string]$p.groupId -and -not [string]$p.group)
  $desired = $(if ($pinned) { $pinned.Dir } elseif ($groupUnknown) { $keeper.Dir } elseif ([string]$p.group) { Join-Path (Join-Path $ProjRoot (Safe-Name ([string]$p.group))) (Safe-Name $pname) } else { Join-Path $ProjRoot (Safe-Name $pname) })
  if ($desired -ine $keeper.Dir) { $plan.Add([pscustomobject]@{ Kind = 'move'; Proj = $p; Hub = $keeper; To = $desired; Ready = $false }) }
}
foreach ($h in $hubs) { if (-not $claimed.ContainsKey($h.File)) { Write-Log ('     not in Orca (left as is): 01_Projects\' + $h.Rel) } }

# ---- Moves wait until they were planned MoveDelayHours earlier ----
$state = @{}
if (Test-Path -LiteralPath $StateFile) { try { (Get-Content -LiteralPath $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json).moves.PSObject.Properties | ForEach-Object { $state[$_.Name] = [string]$_.Value } } catch { } }
$seen = @{}
foreach ($o in @($plan | Where-Object { $_.Kind -eq 'move' })) {
  $key = '{0}|{1}|{2}' -f $o.Proj.id, $o.Hub.Rel, (Rel $o.To $ProjRoot)
  $seen[$key] = $true
  if ($state.ContainsKey($key)) { if (($Now - [datetime]::Parse($state[$key])).TotalHours -ge $MoveDelayHours) { $o.Ready = $true } }
  elseif ($Apply) { $state[$key] = $Now.ToString('s') }
}

# ---- Plan ----
if ($plan.Count -eq 0) { Write-Log 'project tree matches Orca'; if ($Apply -and (Test-Path -LiteralPath $StateFile)) { Remove-Item -LiteralPath $StateFile -Force }; exit 0 }
foreach ($o in $plan) {
  switch ($o.Kind) {
    'merge'  { Write-Log ('plan merge  {0}: 01_Projects\{1} -> 01_Projects\{2}' -f $o.Proj.name, $o.From.Rel, $o.Into.Rel) }
    'relink' { Write-Log ('plan relink {0}: 01_Projects\{1} orca {2} -> {3}' -f $o.Proj.name, $o.Hub.Rel, $o.Hub.Orca, $o.Proj.id) }
    'move'   {
      $key = '{0}|{1}|{2}' -f $o.Proj.id, $o.Hub.Rel, (Rel $o.To $ProjRoot)
      $when = $(if ($o.Ready) { 'ready' } elseif ($state.ContainsKey($key)) { 'waits until ' + ([datetime]::Parse($state[$key]).AddHours($MoveDelayHours)).ToString('yyyy-MM-dd HH:mm') } else { 'first seen now' })
      Write-Log ('plan move   {0}: 01_Projects\{1} -> 01_Projects\{2} ({3})' -f $o.Proj.name, $o.Hub.Rel, (Rel $o.To $ProjRoot), $when)
    }
  }
}
if (-not $Apply) { Write-Host 'Dry run: nothing changed. Run with -Apply to carry out the plan.'; exit 0 }

$heavy = @($plan | Where-Object { $_.Kind -eq 'merge' -or ($_.Kind -eq 'move' -and $_.Ready) })
$doHeavy = ($heavy.Count -le $MaxOps)
if (-not $doHeavy) { Write-Log ("{0} merges and moves exceed MaxOps {1}; only relinks applied, run by hand after checking" -f $heavy.Count, $MaxOps) }

# ---- Apply ----
$RelMap = @{}   # old project folder (relative) -> new one, for the reference DB
$done = @{ merge = 0; relink = 0; move = 0 }
try {
  foreach ($o in $plan) {
    if ($o.Kind -eq 'merge' -and $doHeavy) {
      $label = '01_Projects/' + ($o.From.Rel -replace '\\', '/')
      Merge-Hub $o.From.File $o.Into.File $label
      Merge-Dir $o.From.Dir $o.Into.Dir 'project' $label
      Merge-Dir (Join-Path $RefRoot $o.From.Rel) (Join-Path $RefRoot $o.Into.Rel) 'ref' $label
      Remove-EmptyDirs $o.From.Dir $ProjRoot
      Remove-EmptyDirs (Join-Path $RefRoot $o.From.Rel) $RefRoot
      $RelMap[$o.From.Rel] = $o.Into.Rel
      Write-Log ('merged {0}: 01_Projects\{1} into 01_Projects\{2}' -f $o.Proj.name, $o.From.Rel, $o.Into.Rel); $done.merge++
    }
    elseif ($o.Kind -eq 'relink') {
      Set-Identity $o.Hub.File ([string]$o.Proj.id) $o.Ids $o.Path
      Write-Log ('relinked {0}: 01_Projects\{1}' -f $o.Proj.name, $o.Hub.Rel); $done.relink++
    }
    elseif ($o.Kind -eq 'move' -and $o.Ready -and $doHeavy) {
      if ((Test-Path -LiteralPath (Join-Path $o.To '_index.md'))) { Write-Log ('     skip move {0}: 01_Projects\{1} already has a first page of another project' -f $o.Proj.name, (Rel $o.To $ProjRoot)); continue }
      $label = '01_Projects/' + ($o.Hub.Rel -replace '\\', '/')
      $newRel = Rel $o.To $ProjRoot
      Merge-Dir $o.Hub.Dir $o.To 'project' $label
      Merge-Dir (Join-Path $RefRoot $o.Hub.Rel) (Join-Path $RefRoot $newRel) 'ref' $label
      Remove-EmptyDirs $o.Hub.Dir $ProjRoot
      Remove-EmptyDirs (Join-Path $RefRoot $o.Hub.Rel) $RefRoot
      $RelMap[$o.Hub.Rel] = $newRel
      $state.Remove(('{0}|{1}|{2}' -f $o.Proj.id, $o.Hub.Rel, $newRel))
      Write-Log ('moved {0}: 01_Projects\{1} -> 01_Projects\{2}' -f $o.Proj.name, $o.Hub.Rel, $newRel); $done.move++
    }
  }

  # Reference DB: project folders and note paths follow the files.
  if ($RelMap.Count -and (Test-Path -LiteralPath $DbFile)) {
    $db = @{}
    (Get-Content -LiteralPath $DbFile -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $db[$_.Name] = $_.Value }
    $changed = 0
    foreach ($e in $db.Values) {
      if ($e.project -and $RelMap.ContainsKey([string]$e.project)) { $e.project = $RelMap[[string]$e.project]; $changed++ }
      foreach ($u in @($e.uses)) { if ($u -and $u.project -and $RelMap.ContainsKey([string]$u.project)) { $u.project = $RelMap[[string]$u.project] } }
      if ($e.note) {
        $full = Join-Path $RefRoot ([string]$e.note + '.md')
        if ($Moved.Contains($full)) { $e.note = ((Rel $Moved[$full] $RefRoot) -replace '\.md$', '') }
      }
    }
    Backup-File $DbFile
    [System.IO.File]::WriteAllText($DbFile, (($db.GetEnumerator() | Sort-Object Name | ForEach-Object -Begin { $o = [ordered]@{} } -Process { $o[$_.Name] = $_.Value } -End { $o }) | ConvertTo-Json -Depth 8), $Utf8)
    Write-Log ("reference DB: $changed entries moved to their new project folder")
  }

  # Links written with a folder path to a moved note.
  $map = @{}
  foreach ($k in @($Moved.Keys)) { if ($k -match '\.md$') { $map[((Rel $k $VaultPath) -replace '\\', '/' -replace '\.md$', '')] = ((Rel $Moved[$k] $VaultPath) -replace '\\', '/' -replace '\.md$', '') } }
  if ($map.Count) {
    $keys = @($map.Keys)
    $notes = @(Get-ChildItem -LiteralPath $VaultPath -Directory -Force | Where-Object { $_.Name -notin '99_Private', '.obsidian', '.trash', '.git' } | ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Recurse -File -Filter *.md -Force })
    $notes += @(Get-ChildItem -LiteralPath $VaultPath -File -Filter *.md -Force)
    $fixed = 0
    foreach ($n in $notes) {
      $t = Read-Utf8 $n.FullName
      if ($t.IndexOf('[[') -lt 0) { continue }
      $new = [regex]::Replace($t, '\[\[([^\[\]|#\r\n]+?)(?=[|#\]])', [System.Text.RegularExpressions.MatchEvaluator]{
        param($m)
        $target = ($m.Groups[1].Value.Trim() -replace '\\', '/') -replace '\.md$', ''
        if ($target.IndexOf('/') -lt 0) { return $m.Value }
        $hit = $null
        if ($map.ContainsKey($target)) { $hit = $target } else { foreach ($k in $keys) { if ($k.EndsWith('/' + $target, [System.StringComparison]::OrdinalIgnoreCase)) { $hit = $k; break } } }
        if ($hit) { return '[[' + $map[$hit] } else { return $m.Value }
      })
      if ($new -ne $t) { Backup-File $n.FullName; Write-Utf8 $n.FullName $new; Note-Change ('links | ' + (Rel $n.FullName $VaultPath)); $fixed++ }
    }
    if ($fixed) { Write-Log ("path links fixed in $fixed notes") }
  }
} finally {
  foreach ($k in @($state.Keys)) { if (-not $seen.ContainsKey($k)) { $state.Remove($k) } }
  [System.IO.File]::WriteAllText($StateFile, (@{ moves = $state } | ConvertTo-Json -Depth 3), $Utf8)
  if ((Test-Path -LiteralPath $Stage) -and @(Get-ChildItem -LiteralPath $Stage -Recurse -File).Count) {
    New-Item -ItemType Directory -Force -Path $BackupDir | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = Join-Path $BackupDir ('tree-' + $Now.ToString('yyyyMMdd-HHmmss') + '.zip')
    [System.IO.Compression.ZipFile]::CreateFromDirectory($Stage, $zip)
    Remove-Item -LiteralPath $Stage -Recurse -Force
    Write-Log ('backup: ' + (Rel $zip $VaultPath))
  }
}
Write-Log ('done: {0} merged, {1} relinked, {2} moved' -f $done.merge, $done.relink, $done.move)
