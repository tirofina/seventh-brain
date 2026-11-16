<#
.SYNOPSIS
  Local Hermes (Ollama) nightly processor for the Obsidian Inbox.
.DESCRIPTION
  Scans 00_Inbox for markdown notes, asks the local Hermes model for a short summary, tags
  and related concepts, and appends a folded "자동 제안" callout to each note WITHOUT
  altering the original text. A related concept becomes a [[link]] only when a note of that
  name (or alias) really exists in the vault; the rest stay plain text on their own line,
  so a click never creates an empty note. Every run also re-checks the callouts written
  before, without a model call: a concept whose note has appeared since becomes a link, and
  a link whose note was deleted turns back into plain text. Files are written only when
  something changed. -Redo regenerates the callouts that already exist.
  Built to run headless from Windows Task Scheduler. All model calls stay on localhost.
.NOTES
  Vault and routing rules: 90_Meta/AI-라우팅-치트시트.md. Save as UTF-8 with BOM (PowerShell 5.1).
  99_Private is never read, not even for note names.
#>

[CmdletBinding()]
param(
  [string]$VaultPath = '',
  [string]$InboxRel  = '00_Inbox',
  [string]$Model     = '',
  [string]$ApiBase   = 'http://localhost:11434',
  [int]$MaxChars     = 6000,
  [switch]$Redo
)

$ErrorActionPreference = 'Stop'
# Settings written by install.ps1 (read here: param defaults cannot see the script folder in PowerShell 5.1).
$KitConfig = $null
try { $KitConfig = Get-Content -LiteralPath (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
if ($KitConfig) {
  if (-not $VaultPath) { $VaultPath = [string]$KitConfig.vaultPath }
  if (-not $Model) { $Model = [string]$KitConfig.hermesModel }
}
if (-not $VaultPath -or -not (Test-Path -LiteralPath $VaultPath)) { throw 'config.json is missing or vaultPath is wrong. Run install.ps1 first.' }
$Marker  = '<!-- hermes:processed -->'
$LogPath = Join-Path $VaultPath '90_Meta\scripts\hermes-inbox.log'
# Link targets: every note except private, system and template folders.
$NoTargets = @('99_Private', '90_Meta', '.obsidian', '.trash', '_attachments')
# The callout this script appends (also the older "Hermes 생성 (date)" title), up to the marker.
$BlockRx = [regex]('(?s)(?:\r?\n)*> \[!tip\]- (?:자동 제안|Hermes 생성[^\r\n]*)\r?\n((?:>[^\r\n]*\r?\n)*)' + [regex]::Escape($Marker))
$Schema = @{
  type = 'object'
  properties = [ordered]@{
    summary = @{ type = 'string' }
    tags    = @{ type = 'array'; items = @{ type = 'string' } }
    related = @{ type = 'array'; items = @{ type = 'string' } }
  }
  required = @('summary', 'tags', 'related')
}

function Write-Log([string]$msg) {
  $line = '{0}  {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
  try { Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 } catch { }
  Write-Output $line
}
function Read-Utf8([string]$p) { [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8) }
function Write-Utf8([string]$p, [string]$t) {
  $enc = New-Object System.Text.UTF8Encoding($false)   # UTF-8 without BOM (Obsidian friendly)
  [System.IO.File]::WriteAllText($p, $t, $enc)
}
function Clean-Text([string]$s) {
  # Strip decorative Unicode from model output (user rule: plain ASCII symbols only).
  if ($null -eq $s) { return '' }
  $s = $s -replace '[\u2192\u21D2\u27F6]', '->' -replace '[\u2190\u21D0]', '<-'
  $s = $s -replace '\s*\u00B7\s*', ', ' -replace '\u2022', '-'
  $s = $s -replace '\u2026', '...' -replace '[\u2013\u2014]', '-' -replace '[\u201C\u201D]', '"' -replace '[\u2018\u2019]', "'"
  $s = $s -replace '[\u2190-\u21FF\u2500-\u257F\u2600-\u27BF]', ''
  $s = $s -replace '[\uD83C-\uD83E][\uDC00-\uDFFF]', ''
  return $s
}
function Fix-Style([string]$s) {
  # Plain register ("~다"), proper nouns in English, no stray tags from "#word".
  if (-not $s) { return '' }
  $s = Clean-Text $s
  $s = $s -replace '헤르메스', 'Hermes' -replace '옵시디언', 'Obsidian' -replace '오르카', 'Orca' -replace '클로드', 'Claude'
  $s = [regex]::Replace($s, '(?<![`\w&])#([^\s#`,.;:!?()\[\]{}]+)', '`#$1`')
  $s = [regex]::Replace($s, '(필요|중요|가능|불가능|충분|부족|유용|적합|동일|유사|정확|명확|간단|복잡|편리|안전)합니다', '$1하다')
  $s = $s -replace '합니다', '한다' -replace '됩니다', '된다' -replace '입니다', '이다' -replace '습니다', '다'
  return ($s -replace '\s+', ' ').Trim()
}
function Get-NoteKey([string]$s) { ((([string]$s).Trim()) -replace '[\s_\-]+', '').ToLowerInvariant() }
function Get-NoteIndex {
  # name or alias (spacing and hyphens ignored) -> note base name, for every allowed link target.
  $idx = @{}
  $tops  = @(Get-ChildItem -LiteralPath $VaultPath -Directory | Where-Object { $NoTargets -notcontains $_.Name })
  $notes = @(Get-ChildItem -LiteralPath $VaultPath -File -Filter *.md) +
           @($tops | ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Recurse -File -Filter *.md -ErrorAction SilentlyContinue })
  $notes = @($notes | Where-Object { $_.FullName -notmatch '\\_templates\\' })
  foreach ($n in $notes) { $k = Get-NoteKey $n.BaseName; if ($k -and -not $idx.ContainsKey($k)) { $idx[$k] = $n.BaseName } }
  foreach ($n in $notes) {
    $fm = [regex]::Match((Read-Utf8 $n.FullName), '(?s)^---\s*\r?\n(.*?)\r?\n---')
    if (-not $fm.Success) { continue }
    $y = $fm.Groups[1].Value; $als = @()
    $m1 = [regex]::Match($y, '(?m)^aliases:\s*\[(.*)\]\s*$')
    if ($m1.Success) { $als = @($m1.Groups[1].Value -split ',') }
    else {
      $m2 = [regex]::Match($y, '(?m)^aliases:\s*\r?\n((?:[ \t]+-[^\r\n]*\r?\n?)+)')
      if ($m2.Success) { $als = @($m2.Groups[1].Value -split '\r?\n' | ForEach-Object { $_ -replace '^\s*-\s*', '' }) }
    }
    foreach ($a in $als) { $k = Get-NoteKey ($a.Trim().Trim('"').Trim("'")); if ($k -and -not $idx.ContainsKey($k)) { $idx[$k] = $n.BaseName } }
  }
  return $idx
}
function Read-Block([string]$inner) {
  # Summary, tag line and concept names of a callout written before (any older layout).
  $r = @{ Summary = ''; Tags = ''; Names = @() }
  foreach ($ln in ($inner -split '\r?\n')) {
    $t = ($ln -replace '^>\s?', '').Trim()
    if ($t -match '^요약:\s*(.*)$') { $r.Summary = $Matches[1].Trim() }
    elseif ($t -match '^태그:\s*(.*)$') { $r.Tags = $Matches[1].Trim() }
    elseif ($t -match '^(링크 제안|관련 노트|관련 개념):\s*(.*)$') {
      foreach ($part in ($Matches[2] -split ',\s*')) {
        $x = $part.Trim()
        $m = [regex]::Match($x, '^\[\[([^\]|]+)(?:\|([^\]]+))?\]\]$')
        if ($m.Success) { $x = if ($m.Groups[2].Success) { $m.Groups[2].Value } else { $m.Groups[1].Value } }
        if ($x) { $r.Names += $x.Trim() }
      }
    }
  }
  if ($r.Summary -eq '(요약 없음)') { $r.Summary = '' }
  if ($r.Tags -eq '(없음)') { $r.Tags = '' }
  $r.Names = @($r.Names | Where-Object { $_ -and $_ -ne '(없음)' })
  return $r
}
function Build-Block([string]$summary, [string]$tagLine, $names, $idx, [string]$self) {
  # Existing notes become links; everything else stays plain text. No empty lines, no "(없음)".
  $linked = New-Object System.Collections.Generic.List[string]
  $plain  = New-Object System.Collections.Generic.List[string]
  $seen = @{ (Get-NoteKey $self) = $true }
  foreach ($c in @($names)) {
    $name = ((Clean-Text ([string]$c)) -replace '[\[\]#|`]', '' -replace '\s+', ' ').Trim()
    $name = [regex]::Replace($name, '(?<=[가-힣])-|-(?=[가-힣])', ' ')   # tag-style "신경계-균형" reads as "신경계 균형"
    if (-not $name) { continue }
    $k = Get-NoteKey $name
    if ($seen.ContainsKey($k)) { continue }
    $seen[$k] = $true
    if ($idx.ContainsKey($k)) {
      $target = $idx[$k]
      if ($target -eq $name) { $linked.Add("[[$target]]") } else { $linked.Add("[[$target|$name]]") }
    } else { $plain.Add($name) }
  }
  $lines = @('> [!tip]- 자동 제안')
  if ($summary) { $lines += "> 요약: $summary" }
  if ($tagLine) { $lines += "> 태그: $tagLine" }
  if ($linked.Count -gt 0) { $lines += ('> 관련 노트: ' + ($linked -join ', ')) }
  if ($plain.Count -gt 0)  { $lines += ('> 관련 개념: ' + ($plain -join ', ')) }
  return (($lines -join "`n") + "`n" + $Marker)
}
function Set-Block([string]$content, [string]$block) {
  # Replace the last callout this script wrote, or append one; text after the marker is kept.
  $ms = $BlockRx.Matches($content)
  if ($ms.Count -gt 0) {
    $m = $ms[$ms.Count - 1]
    return ($content.Substring(0, $m.Index).TrimEnd() + "`n`n" + $block + $content.Substring($m.Index + $m.Length))
  }
  $body = $content.Replace($Marker, '').TrimEnd()
  return ($body + "`n`n" + $block + "`n")
}

$InboxPath = Join-Path $VaultPath $InboxRel
if (-not (Test-Path -LiteralPath $InboxPath)) { Write-Log "ERROR: Inbox not found: $InboxPath"; exit 1 }

$files = @(Get-ChildItem -LiteralPath $InboxPath -Filter *.md -File)
if ($files.Count -eq 0) { Write-Log 'Inbox empty. Nothing to do.'; exit 0 }

$idx = Get-NoteIndex
$genUri = "$ApiBase/api/generate"
$ollamaUp = $true
try { $null = Invoke-RestMethod -Uri $ApiBase -TimeoutSec 5 } catch { $ollamaUp = $false }
if (-not $ollamaUp) { Write-Log "WARN: Ollama not reachable at $ApiBase. Only re-checking links of processed notes." }

# Concept and reference notes the model may point to by their exact title.
$known = @(foreach ($d in @('02_Notes', '04_References')) {
  $p = Join-Path $VaultPath $d
  if (Test-Path -LiteralPath $p) { Get-ChildItem -LiteralPath $p -Recurse -File -Filter *.md | ForEach-Object { $_.BaseName } }
}) | Select-Object -First 150
$knownText = if ($known.Count -gt 0) { "`n볼트에 있는 노트 (맞는 것이 있으면 related에 이 제목을 그대로 쓴다):`n" + (($known | ForEach-Object { '- ' + $_ }) -join "`n") + "`n" } else { '' }

$processed = 0; $relinked = 0; $skipped = 0; $failed = 0

foreach ($f in $files) {
  try {
    $content = Read-Utf8 $f.FullName
    if ([string]::IsNullOrWhiteSpace($content)) { $skipped++; continue }
    $done = $content.Contains($Marker)

    if ($done -and -not $Redo) {
      # ---- Re-check an earlier callout: links follow the notes that exist now (no model call) ----
      $ms = $BlockRx.Matches($content)
      if ($ms.Count -eq 0) { $skipped++; continue }
      $old = Read-Block $ms[$ms.Count - 1].Groups[1].Value
      $new = Set-Block $content (Build-Block (Fix-Style $old.Summary) $old.Tags $old.Names $idx $f.BaseName)
      if ($new -ne $content) { Write-Utf8 $f.FullName $new; Write-Log ('LINK {0}  callout re-checked' -f $f.Name); $relinked++ } else { $skipped++ }
      continue
    }
    if (-not $ollamaUp) { $skipped++; continue }

    # ---- New note (or -Redo): ask Hermes, on the note text without our earlier callout ----
    $text = $BlockRx.Replace($content, '').Replace($Marker, '').TrimEnd()
    $snippet = if ($text.Length -gt $MaxChars) { $text.Substring(0, $MaxChars) } else { $text }
    $prompt = @"
다음은 Obsidian 연구 노트다. 아래 항목을 JSON 객체 하나로만 답한다. 코드펜스나 설명은 쓰지 않는다.
- summary: 노트의 핵심을 한국어 1-2문장으로 쓴다. 평서문으로 쓰고 "~다"로 끝낸다. "~습니다", "~음", "~함"으로 끝내지 않는다.
- tags: 노트의 주제를 나타내는 태그 3-6개. 띄어쓰기 대신 하이픈을 쓴다.
- related: 이 노트와 이어지는 개념 2-5개를 짧은 명사로 쓴다.
고유명사와 약어(Claude, Hermes, Orca, Obsidian, PPG, HRV, EDA 등)는 영어 표기 그대로 쓴다.
$knownText
노트 내용:
---
$snippet
---
"@
    $req = @{ model = $Model; prompt = $prompt; stream = $false; format = $Schema; options = @{ temperature = 0.2; num_ctx = 16384 } } | ConvertTo-Json -Depth 10
    $resp = Invoke-RestMethod -Uri $genUri -Method Post -Body ([System.Text.Encoding]::UTF8.GetBytes($req)) -ContentType 'application/json; charset=utf-8' -TimeoutSec 300
    $raw  = ([string]$resp.response) -replace '^\s*```(?:json)?\s*', '' -replace '\s*```\s*$', ''
    $data = $raw | ConvertFrom-Json

    $summary = Fix-Style ([string]$data.summary)
    $tags = @(@($data.tags) | ForEach-Object { ((Clean-Text ([string]$_)).Trim() -replace '^#+', '' -replace '\s+', '-' -replace '[^\p{L}\p{N}_\-/]', '') } |
      Where-Object { $_ -and $_ -notmatch '^[\d\-_/]+$' } | Select-Object -Unique)
    $tagLine = ($tags | ForEach-Object { '#' + $_ }) -join ' '
    $names = @(@($data.related) | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ })
    if (-not $summary -and -not $tagLine -and $names.Count -eq 0) { Write-Log ('SKIP {0}  empty answer, will retry next run' -f $f.Name); $skipped++; continue }

    $new = Set-Block $content (Build-Block $summary $tagLine $names $idx $f.BaseName)
    Write-Utf8 $f.FullName $new
    Write-Log ('OK   {0}  tags=[{1}]' -f $f.Name, ($tags -join ', '))
    $processed++
  }
  catch {
    Write-Log ('FAIL {0}  {1}' -f $f.Name, $_.Exception.Message)
    $failed++
  }
}

Write-Log ('Done. processed={0} relinked={1} skipped={2} failed={3}' -f $processed, $relinked, $skipped, $failed)
