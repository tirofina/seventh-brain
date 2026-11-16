<#
.SYNOPSIS
  Collect the papers and links cited in recent AI sessions into 04_References/<project>, organized per Orca project.
.DESCRIPTION
  Sources: Claude Code transcripts (and Codex transcripts converted by codex-to-claude.ps1) changed
  in the last SinceHours. Kept: URLs, DOIs and arXiv ids written in user or assistant text, and
  pages the agent opened with WebFetch. Search-result lists inside tool output are not read, so only
  what was cited or opened ends up here. Local and API addresses are dropped.
  Each session is placed in its Orca project the same way the capture step does it
  (orca-projects.json, then the project's first page with an "orca:" id); the reference folder
  mirrors the project folder: 01_Projects/<group>/<project> -> 04_References/<group>/<project>.
  Papers (DOI, arXiv, PubMed) get one note each, named by title, with metadata from the public
  Crossref, arXiv or PubMed APIs (only the identifier is sent, nothing from the conversation),
  a folded abstract when available, and an auto section "어디서 썼나" listing the work logs and
  the sentence the paper came up in. Other links are listed in "<project> 참고 자료.md".
  Everything inside <!-- auto:ref... --> markers is rebuilt each run from references-db.json;
  text written outside the markers is kept.
  Save as UTF-8 with BOM (PowerShell 5.1).
#>
[CmdletBinding()]
param(
  [string]$VaultPath = '',
  [string[]]$ProjectsBase = @(),
  [int]$SinceHours = 168
)
$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12   # PS 5.1 default lacks TLS 1.2
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$KitConfig = $null
try { $KitConfig = Get-Content -LiteralPath (Join-Path $ScriptDir 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
if (-not $VaultPath) { $VaultPath = $(if ($KitConfig -and $KitConfig.vaultPath) { [string]$KitConfig.vaultPath } else { Split-Path -Parent (Split-Path -Parent $ScriptDir) }) }
if ($ProjectsBase.Count -eq 0) {
  $ProjectsBase = @($(if ($KitConfig -and $KitConfig.claudeProjects) { [string]$KitConfig.claudeProjects } else { Join-Path $env:USERPROFILE '.claude\projects' }))
  $codexOut = Join-Path $ScriptDir 'codex-transcripts'
  if (Test-Path -LiteralPath $codexOut) { $ProjectsBase += $codexOut }
}
$LogPath   = Join-Path $ScriptDir 'hermes-inbox.log'
$DbFile    = Join-Path $ScriptDir 'references-db.json'
$StateFile = Join-Path $ScriptDir 'references-state.json'
$ProjRoot  = Join-Path $VaultPath '01_Projects'
$RefRoot   = Join-Path $VaultPath '04_References'
$Utf8      = New-Object System.Text.UTF8Encoding($false)
$Today     = Get-Date -Format 'yyyy-MM-dd'
$UA        = 'seventh-brain-references/1.0'

function Write-Log([string]$m) {
  $line = '{0}  [refs] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m
  try { Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 } catch { }
  Write-Output $line
}
function Read-Utf8([string]$p) { $t = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8); if ($t.Length -gt 0 -and $t[0] -eq [char]0xFEFF) { $t = $t.Substring(1) }; return $t }
function Write-Utf8([string]$p, [string]$t) { $d = Split-Path -Parent $p; if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }; [System.IO.File]::WriteAllText($p, $t, $Utf8) }
function Safe-Name([string]$s, [int]$max) {
  $s = ($s -replace '[\\/:*?"<>|#^\[\]]', ' ' -replace '\s+', ' ').Trim().TrimEnd('.')
  if ($s.Length -gt $max) { $s = $s.Substring(0, $max).Trim() }
  return $s
}
function Clean([string]$s) {
  $s = [regex]::Replace([string]$s, '<[^>]+>', ' ')
  $s = $s -replace '[‐-―]', '-' -replace '[‘’]', "'" -replace '[“”]', '"' -replace '…', '...' -replace '·', ', ' -replace '[←-⇿]', '->'
  $s = [regex]::Replace($s, '[^\u0009\u000A\u000D -~ -ÿĀ-ɏͰ-Ͽᄀ-ᇿ㄰-㆏가-힣]', '')
  return ($s -replace '\s+', ' ').Trim()
}

# ---- Project of a working directory (same rules as capture-sessions.ps1) ----
$OrcaProjects = @()
$mapFile = Join-Path $ScriptDir 'orca-projects.json'
if (Test-Path -LiteralPath $mapFile) { try { $OrcaProjects = @((Get-Content -LiteralPath $mapFile -Raw -Encoding UTF8 | ConvertFrom-Json).projects) } catch { } }
$OrcaRoot = $(if ($KitConfig -and $KitConfig.orcaRoot) { [string]$KitConfig.orcaRoot } else { Join-Path $env:USERPROFILE 'orca' })
$hubs = @()
if (Test-Path -LiteralPath $ProjRoot) {
  foreach ($h in @(Get-ChildItem -LiteralPath $ProjRoot -Recurse -Depth 2 -Filter '_index.md' -File)) {
    $fm = [regex]::Match((Read-Utf8 $h.FullName), '(?s)\A---\r?\n(.*?)\r?\n---').Groups[1].Value
    $hubs += [pscustomobject]@{ Dir = $h.DirectoryName; Orca = ([regex]::Match($fm, '(?m)^orca:\s*"?([^"\r\n]+?)"?\s*$')).Groups[1].Value; Tags = ([regex]::Match($fm, '(?m)^tags:\s*\[(.*)\]')).Groups[1].Value }
  }
}
function Get-ProjectRel([string]$cwd) {
  # Returns the project folder relative to 01_Projects (e.g. "My Group\My Project"), or '' when not an Orca project.
  if (-not $cwd) { return '' }
  $c = ($cwd -replace '/', '\').TrimEnd('\')
  $best = $null; $bestLen = -1
  foreach ($p in $OrcaProjects) { foreach ($e in @($p.paths)) {
    $ep = ([string]$e.path).TrimEnd('\')
    if (($c -ieq $ep -or $c.StartsWith($ep + '\', [System.StringComparison]::OrdinalIgnoreCase)) -and $ep.Length -gt $bestLen) { $bestLen = $ep.Length; $best = $p }
  } }
  $id = ''; $name = ''; $group = ''; $folder = ''
  if ($best) { $id = [string]$best.id; $name = [string]$best.name; $group = [string]$best.group; $folder = [string]$best.folder }
  else {
    $m = [regex]::Match($c, '^' + [regex]::Escape($OrcaRoot.TrimEnd('\')) + '\\(?:workspaces|projects)\\([^\\]+)', 'IgnoreCase')
    if (-not $m.Success) { return '' }
    $folder = $m.Groups[1].Value; $name = $folder
    $p = @($OrcaProjects | Where-Object { $_.folder -ieq $folder }) | Select-Object -First 1
    if ($p) { $id = [string]$p.id; $name = [string]$p.name; $group = [string]$p.group }
  }
  foreach ($h in $hubs) {
    $tags = @($h.Tags -split ',' | ForEach-Object { $_.Trim().Trim('"') })
    if (($id -and $h.Orca -eq $id) -or $h.Orca -eq $name -or $tags -contains $name -or ($folder -and $tags -contains $folder)) { return $h.Dir.Substring($ProjRoot.Length).TrimStart('\') }
  }
  return $(if ($group) { (Safe-Name $group 60) + '\' + (Safe-Name $name 60) } else { Safe-Name $name 60 })
}

# ---- Work log note of each session (by its capture marker) ----
$logBySid = @{}
if (Test-Path -LiteralPath $ProjRoot) {
  foreach ($n in @(Get-ChildItem -LiteralPath $ProjRoot -Recurse -Filter *.md -File | Where-Object { $_.FullName -match '\\log\\' })) {
    foreach ($mm in [regex]::Matches((Read-Utf8 $n.FullName), '<!-- session-capture:([0-9A-Za-z-]+) -->')) { $logBySid[$mm.Groups[1].Value] = $n.BaseName }
  }
}

# ---- Identifier extraction ----
$skipHost = '^(localhost|127\.|0\.0\.0\.0|\[::1\]|.*\.local$|api\.[^/]+|schemas?\.|www\.w3\.org|json-schema\.org|claude\.ai|console\.anthropic\.com|example\.(com|org)|.*\.example$|drive\.google\.com|docs\.google\.com|.*\.sharepoint\.com|onedrive\.live\.com|1drv\.ms|(www\.)?dropbox\.com)'   # last ones: personal storage, not references
function Get-Refs([string]$text) {
  $out = New-Object System.Collections.Generic.List[object]
  if (-not $text) { return $out }
  $t = [regex]::Replace($text, '(?ms)^```.*?^```', ' ')   # code blocks are code, not citations
  foreach ($m in [regex]::Matches($t, 'https?://[^\s<>"''`\)\]\}|]+')) {
    $u = $m.Value.TrimEnd('.', ',', ';', ':', '!', '?', '*', '_')
    $hostName = ([regex]::Match($u, '^https?://([^/:?#]+)')).Groups[1].Value.ToLowerInvariant()
    if ($hostName -match $skipHost) { continue }
    $out.Add([pscustomobject]@{ Raw = $u; Pos = $m.Index })
  }
  foreach ($m in [regex]::Matches($t, '(?<![/\w.])(?:doi:\s*)?(10\.\d{4,9}/[^\s<>"''`\)\]\},;]+)', 'IgnoreCase')) {
    $out.Add([pscustomobject]@{ Raw = 'https://doi.org/' + $m.Groups[1].Value.TrimEnd('.'); Pos = $m.Index })
  }
  foreach ($m in [regex]::Matches($t, '(?<![/\w.])arXiv:\s?(\d{4}\.\d{4,5})(v\d+)?', 'IgnoreCase')) {
    $out.Add([pscustomobject]@{ Raw = 'https://arxiv.org/abs/' + $m.Groups[1].Value; Pos = $m.Index })
  }
  return $out
}
function Get-Key([string]$u) {
  $m = [regex]::Match($u, '(?i)(?:doi\.org/|/doi/(?:abs/|full/|pdf/)?)(10\.\d{4,9}/[^\s?#]+)')
  if ($m.Success) { return @{ Kind = 'doi'; Id = ($m.Groups[1].Value.TrimEnd('/').ToLowerInvariant() -replace '\.(pdf|full)$', '') } }
  $m = [regex]::Match($u, '(?i)arxiv\.org/(?:abs|pdf)/(\d{4}\.\d{4,5})')
  if ($m.Success) { return @{ Kind = 'arxiv'; Id = $m.Groups[1].Value } }
  $m = [regex]::Match($u, '(?i)(?:pmc\.ncbi\.nlm\.nih\.gov/articles/|ncbi\.nlm\.nih\.gov/pmc/articles/|europepmc\.org/article/PMC/)(?:PMC)?(\d+)')
  if ($m.Success) { return @{ Kind = 'pmc'; Id = 'PMC' + $m.Groups[1].Value } }
  $m = [regex]::Match($u, '(?i)(?:pubmed\.ncbi\.nlm\.nih\.gov/|ncbi\.nlm\.nih\.gov/pubmed/)(\d+)')
  if ($m.Success) { return @{ Kind = 'pmid'; Id = $m.Groups[1].Value } }
  $n = ($u -replace '#.*$', '' -replace '/+$', '')
  return @{ Kind = 'url'; Id = $n }
}
function Get-Context([string]$text, [int]$pos) {
  $s = [Math]::Max(0, $text.LastIndexOfAny([char[]]"`n", [Math]::Max(0, $pos - 1)))
  $e = $text.IndexOf("`n", $pos); if ($e -lt 0) { $e = $text.Length }
  $line = $text.Substring($s, $e - $s)
  $line = [regex]::Replace($line, '\[([^\]]*)\]\([^)]*\)', '$1')
  $line = [regex]::Replace($line, 'https?://\S+', '')
  $line = (Clean ($line -replace '[*_`#>|]', ' ')).Trim(' ', '-', ':')
  if ($line.Length -gt 160) { $line = $line.Substring(0, 160).Trim() + '...' }
  return $line
}

# ---- Metadata from public APIs (identifier only) ----
function Get-Meta($k) {
  try {
    if ($k.Kind -eq 'doi') {
      # Publisher URLs often add a path after the DOI (.../10.1093/x/y/7287063): drop trailing parts until Crossref knows it.
      $try = $k.Id; $r = $null
      while ($true) {
        try { $r = Invoke-RestMethod -Uri ('https://api.crossref.org/works/' + [uri]::EscapeDataString($try)) -UserAgent $UA -TimeoutSec 20; break } catch { }
        $cut = $try.LastIndexOf('/')
        if ($cut -le $try.IndexOf('/')) { throw 'not found in Crossref' }
        $try = $try.Substring(0, $cut)
      }
      $k.Id = $try
      $w = $r.message
      $authors = @(@($w.author) | Select-Object -First 6 | ForEach-Object { (([string]$_.given + ' ' + [string]$_.family).Trim()) })
      $year = ''
      foreach ($f in 'published-print', 'published-online', 'issued', 'created') { if ($w.$f.'date-parts') { $year = [string]@(@($w.$f.'date-parts')[0])[0]; if ($year) { break } } }
      return @{ Title = Clean (@($w.title)[0]); Authors = $authors; MoreAuthors = (@($w.author).Count -gt 6); Year = $year; Venue = Clean (@($w.'container-title')[0]); Abstract = Clean ([string]$w.abstract); Url = 'https://doi.org/' + $k.Id }
    }
    if ($k.Kind -eq 'arxiv') {
      $x = [xml](Invoke-WebRequest -Uri ('https://export.arxiv.org/api/query?id_list=' + $k.Id) -UserAgent $UA -TimeoutSec 20 -UseBasicParsing).Content
      $e = $x.feed.entry
      return @{ Title = Clean $e.title; Authors = @(@($e.author) | Select-Object -First 6 | ForEach-Object { Clean $_.name }); MoreAuthors = (@($e.author).Count -gt 6); Year = ([string]$e.published).Substring(0, 4); Venue = 'arXiv'; Abstract = Clean $e.summary; Url = 'https://arxiv.org/abs/' + $k.Id }
    }
    if ($k.Kind -eq 'pmc') {
      $num = $k.Id -replace '^PMC', ''
      $r = Invoke-RestMethod -Uri ('https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esummary.fcgi?db=pmc&retmode=json&id=' + $num) -UserAgent $UA -TimeoutSec 20
      $d = $r.result.$num
      if (-not $d -or -not $d.title) { throw 'not found in PMC' }
      return @{ Title = Clean $d.title; Authors = @(@($d.authors) | Select-Object -First 6 | ForEach-Object { Clean $_.name }); MoreAuthors = (@($d.authors).Count -gt 6); Year = ([string]$d.pubdate).Substring(0, 4); Venue = Clean $d.fulljournalname; Abstract = ''; Url = 'https://pmc.ncbi.nlm.nih.gov/articles/' + $k.Id + '/' }
    }
    if ($k.Kind -eq 'pmid') {
      $r = Invoke-RestMethod -Uri ('https://eutils.ncbi.nlm.nih.gov/entrez/eutils/esummary.fcgi?db=pubmed&retmode=json&id=' + $k.Id) -UserAgent $UA -TimeoutSec 20
      $d = $r.result.($k.Id)
      return @{ Title = Clean $d.title; Authors = @(@($d.authors) | Select-Object -First 6 | ForEach-Object { Clean $_.name }); MoreAuthors = (@($d.authors).Count -gt 6); Year = ([string]$d.pubdate).Substring(0, 4); Venue = Clean $d.fulljournalname; Abstract = ''; Url = 'https://pubmed.ncbi.nlm.nih.gov/' + $k.Id + '/' }
    }
  } catch { Write-Log ("WARN metadata for {0}:{1} unavailable ({2})" -f $k.Kind, $k.Id, $_.Exception.Message) | Out-Null }
  return $null
}

# ---- Load state and database ----
$state = @{}
if (Test-Path -LiteralPath $StateFile) { try { (Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $state[$_.Name] = [long]$_.Value } } catch { } }
$db = @{}
if (Test-Path -LiteralPath $DbFile) { try { (Get-Content -LiteralPath $DbFile -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $db[$_.Name] = $_.Value } } catch { } }
# Drop links the exclusion list now covers (the list can grow).
foreach ($key in @($db.Keys)) {
  $h = ([regex]::Match([string]$db[$key].url, '^https?://([^/:?#]+)')).Groups[1].Value.ToLowerInvariant()
  if ($db[$key].kind -eq 'url' -and $h -match $skipHost) { $db.Remove($key) }
}
function New-Entry($key, $k, [string]$url) { return [pscustomobject]@{ key = $key; kind = $k.Kind; id = $k.Id; url = $url; meta = $null; note = ''; project = ''; first = $Today; uses = @() } }

# ---- Scan sessions ----
$cutoff = (Get-Date).AddHours(-$SinceHours)
$files = @(foreach ($b in $ProjectsBase) { if (Test-Path -LiteralPath $b) { Get-ChildItem -LiteralPath $b -Recurse -Filter *.jsonl -File | Where-Object { $_.Directory.Name -ne 'subagents' -and $_.BaseName -notlike 'agent-*' -and $_.LastWriteTime -ge $cutoff } } })
$scanned = 0; $newRefs = 0
foreach ($f in $files) {
  $sid = $f.BaseName
  if ($state.ContainsKey($sid) -and $state[$sid] -ge $f.LastWriteTime.Ticks) { continue }
  $cwd = ''; $found = New-Object System.Collections.Generic.List[object]
  foreach ($l in [System.IO.File]::ReadLines($f.FullName, [System.Text.Encoding]::UTF8)) {
    if ($l -notmatch '"type"\s*:\s*"(user|assistant)"') { continue }
    if ($l -notmatch 'https?://|10\.\d{4}|arxiv') { if (-not $cwd -and $l -match '"cwd"') { try { $cwd = [string]($l | ConvertFrom-Json).cwd } catch { } }; continue }
    $o = $null; try { $o = $l | ConvertFrom-Json } catch { continue }
    if (-not $cwd -and $o.cwd) { $cwd = [string]$o.cwd }
    if ($null -eq $o.message) { continue }
    $blocks = if ($o.message.content -is [string]) { @([pscustomobject]@{ type = 'text'; text = $o.message.content }) } else { @($o.message.content) }
    foreach ($bk in $blocks) {
      if ($bk.type -eq 'text' -and $bk.text) {
        $txt = [regex]::Replace([string]$bk.text, '(?s)<system-reminder>.*?</system-reminder>', '')
        foreach ($r in Get-Refs $txt) { $found.Add([pscustomobject]@{ Url = $r.Raw; Ctx = (Get-Context $txt $r.Pos) }) }
      } elseif ($bk.type -eq 'tool_use' -and $bk.name -eq 'WebFetch' -and $bk.input.url) {
        $found.Add([pscustomobject]@{ Url = [string]$bk.input.url; Ctx = (Clean ([string]$bk.input.prompt)) })
      }
    }
  }
  $state[$sid] = $f.LastWriteTime.Ticks
  $scanned++
  if ($found.Count -eq 0) { continue }
  $rel = Get-ProjectRel $cwd
  if (-not $rel) { continue }
  $logName = $(if ($logBySid.ContainsKey($sid)) { $logBySid[$sid] } else { '' })
  foreach ($fr in $found) {
    $k = Get-Key $fr.Url
    $key = $k.Kind + ':' + $k.Id
    if (-not $db.ContainsKey($key)) { $db[$key] = New-Entry $key $k $fr.Url; $db[$key].project = $rel; $newRefs++ }
    $e = $db[$key]
    $use = [pscustomobject]@{ sid = $sid; project = $rel; log = $logName; ctx = $fr.Ctx }
    $e.uses = @(@($e.uses | Where-Object { $_.sid -ne $sid -or $_.ctx -ne $fr.Ctx }) + $use) | Select-Object -Last 12
  }
}

# ---- Metadata for new papers ----
foreach ($e in @($db.Values | Where-Object { $_.kind -ne 'url' -and $null -eq $_.meta })) {
  $m = Get-Meta @{ Kind = $e.kind; Id = $e.id }
  if ($m) { $e.meta = [pscustomobject]$m }
  Start-Sleep -Milliseconds 300
}

# ---- Write notes ----
$MarkS = '<!-- auto:ref:start -->'; $MarkE = '<!-- auto:ref:end -->'   # not $S/$E: PowerShell names are case-insensitive and $e is a loop variable
function Set-Auto([string]$file, [string]$head, [string]$auto, [string]$tail) {
  # Rebuild only the auto section; keep anything a person wrote outside it.
  $block = $MarkS + "`n" + $auto.Trim() + "`n" + $MarkE
  if (Test-Path -LiteralPath $file) {
    $t = Read-Utf8 $file
    $i = $t.IndexOf($MarkS); $j = $t.IndexOf($MarkE)
    if ($i -ge 0 -and $j -gt $i) { $new = $t.Substring(0, $i) + $block + $t.Substring($j + $MarkE.Length) } else { $new = $t.TrimEnd() + "`n`n" + $block + "`n" }
    if ($new -ne $t) { Write-Utf8 $file $new }
  } else { Write-Utf8 $file ($head + $block + "`n" + $tail) }
}
function Use-Lines($e) {
  $lines = foreach ($u in @($e.uses)) {
    $where = $(if ($u.log) { '[[' + $u.log + ']]' } else { '작업 기록 없음' })
    $c = $(if ($u.ctx) { ': ' + $u.ctx } else { '' })
    '- ' + $where + $c
  }
  return (@($lines | Select-Object -Unique) -join "`n")
}
$names = @{}
foreach ($e in @($db.Values | Where-Object { $_.kind -ne 'url' })) {
  $m = $e.meta
  $title = $(if ($m -and $m.Title) { [string]$m.Title } else { ($e.kind + ' ' + $e.id) })
  if (-not $e.note) {
    $base = Safe-Name $title 80
    if (-not $base) { $base = Safe-Name ($e.kind + ' ' + $e.id) 80 }
    $dir = Join-Path $RefRoot $e.project
    $cand = $base; $n = 2
    while ($names.ContainsKey($cand.ToLowerInvariant()) -or ((Test-Path -LiteralPath (Join-Path $dir ($cand + '.md'))) -and -not ((Read-Utf8 (Join-Path $dir ($cand + '.md'))).Contains('ref-key: "' + $e.key + '"')))) { $cand = $base + ' ' + $n; $n++ }
    $e.note = ($e.project + '\' + $cand)
  }
  $names[(Split-Path -Leaf $e.note).ToLowerInvariant()] = $true
  $file = Join-Path $RefRoot ($e.note + '.md')
  $authors = $(if ($m) { (@($m.Authors) -join ', ') + $(if ($m.MoreAuthors) { ' 외' } else { '' }) } else { '' })
  $first = $(if ($m -and @($m.Authors).Count -gt 0) { (@($m.Authors)[0] -split ' ')[-1] + $(if (@($m.Authors).Count -gt 1) { ' 외' } else { '' }) } else { '' })
  $cite = (@($first, $(if ($m) { [string]$m.Year } else { '' }), $(if ($m) { [string]$m.Venue } else { '' })) | Where-Object { $_ }) -join ', '
  $url = $(if ($m -and $m.Url) { [string]$m.Url } else { [string]$e.url })
  $fmLines = @('---', 'tags: [참고문헌]', 'type: 논문', ('title: "' + ($title -replace '"', "'") + '"'), ('authors: "' + ($authors -replace '"', "'") + '"'),
    ('year: ' + $(if ($m) { [string]$m.Year } else { '' })), ('venue: "' + $(if ($m) { ([string]$m.Venue -replace '"', "'") } else { '' }) + '"'),
    ($e.kind + ': "' + $e.id + '"'), ('url: "' + $url + '"'), ('ref-key: "' + $e.key + '"'), 'source: hermes', ('created: ' + $e.first), ('updated: ' + $Today), '---', '')
  $head = ($fmLines -join "`n") + "`n" + '> [!summary] ' + $title + $(if ($cite) { ' (' + $cite + ')' } else { '' }) + "`n`n" + '[원문 열기](' + $url + ')' + "`n`n"
  $abs = $(if ($m -and $m.Abstract) { "`n> [!info]- 초록`n> " + $m.Abstract + "`n" } else { '' })
  $auto = '## 어디서 썼나' + "`n" + (Use-Lines $e) + "`n" + $abs
  Set-Auto $file $head $auto ("`n## 메모`n")
}

# Project index: papers and other links of each project.
foreach ($proj in @($db.Values | ForEach-Object { $_.project } | Select-Object -Unique)) {
  $pname = Split-Path -Leaf $proj
  $file = Join-Path $RefRoot ($proj + '\' + $pname + ' 참고 자료.md')
  $papers = @($db.Values | Where-Object { $_.project -eq $proj -and $_.kind -ne 'url' } | Sort-Object { $_.first } -Descending)
  $links  = @($db.Values | Where-Object { $_.project -eq $proj -and $_.kind -eq 'url' } | Sort-Object { $_.first } -Descending)
  $pl = foreach ($e in $papers) {
    $m = $e.meta
    $cite = (@($(if ($m -and @($m.Authors).Count) { (@($m.Authors)[0] -split ' ')[-1] } else { '' }), $(if ($m) { [string]$m.Year } else { '' })) | Where-Object { $_ }) -join ' '
    '- [[' + (Split-Path -Leaf $e.note) + ']]' + $(if ($cite) { ' (' + $cite + ')' } else { '' })
  }
  $ll = foreach ($e in $links) {
    $u = @($e.uses) | Select-Object -Last 1
    $label = (($e.url -replace '^https?://(www\.)?', '') -replace '[\[\]]', '')
    if ($label.Length -gt 70) { $label = $label.Substring(0, 70) + '...' }
    '- [' + $label + '](' + $e.url + ')' + $(if ($u.ctx) { ': ' + $u.ctx } else { '' }) + $(if ($u.log) { ' [[' + $u.log + ']]' } else { '' })
  }
  $auto = $(if ($pl) { "## 논문`n" + ($pl -join "`n") + "`n`n" } else { '' }) + $(if ($ll) { "## 링크`n" + ($ll -join "`n") + "`n" } else { '' })
  $head = "---`ntags: [참고문헌]`nsource: hermes`ncreated: $Today`nupdated: $Today`n---`n`n> [!summary] $pname 작업에서 인용하거나 열어 본 논문과 링크다. 대화에서 자동으로 모은다.`n`n"
  Set-Auto $file $head $auto "`n## 메모`n"
}

# Project first pages: a short "참고 자료" section kept current by this script (not by the model).
foreach ($proj in @($db.Values | ForEach-Object { $_.project } | Select-Object -Unique)) {
  $hub = Join-Path $ProjRoot ($proj + '\_index.md')
  if (-not (Test-Path -LiteralPath $hub)) { continue }
  $pname = Split-Path -Leaf $proj
  $papers = @($db.Values | Where-Object { $_.project -eq $proj -and $_.kind -ne 'url' } | Sort-Object { $_.first } -Descending)
  $nl = @($db.Values | Where-Object { $_.project -eq $proj -and $_.kind -eq 'url' }).Count
  $recent = @($papers | Select-Object -First 3 | ForEach-Object { '[[' + (Split-Path -Leaf $_.note) + ']]' }) -join ', '
  $body = "## 참고 자료 (자동 갱신)`n<!-- auto:refs:start -->`n- [[$pname 참고 자료]]: 논문 $($papers.Count)편, 링크 $($nl)개" + $(if ($recent) { "`n- 최근 논문: $recent" } else { '' }) + "`n<!-- auto:refs:end -->"
  $t = Read-Utf8 $hub
  $i = $t.IndexOf('## 참고 자료 (자동 갱신)'); $j = $t.IndexOf('<!-- auto:refs:end -->')
  $new = if ($i -ge 0 -and $j -gt $i) { $t.Substring(0, $i) + $body + $t.Substring($j + '<!-- auto:refs:end -->'.Length) } else { $t.TrimEnd() + "`n`n" + $body + "`n" }
  if ($new -ne $t) { Write-Utf8 $hub $new }
}

# ---- Save ----
[System.IO.File]::WriteAllText($DbFile, (($db.GetEnumerator() | Sort-Object Name | ForEach-Object -Begin { $o = [ordered]@{} } -Process { $o[$_.Name] = $_.Value } -End { $o }) | ConvertTo-Json -Depth 8), $Utf8)
try { ($state | ConvertTo-Json) | Set-Content -LiteralPath $StateFile -Encoding UTF8 } catch { }
Write-Log ("Done. sessions={0} new_refs={1} papers={2} links={3}" -f $scanned, $newRefs, @($db.Values | Where-Object { $_.kind -ne 'url' }).Count, @($db.Values | Where-Object { $_.kind -eq 'url' }).Count)
