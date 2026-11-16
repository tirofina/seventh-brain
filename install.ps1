<#
.SYNOPSIS
  제7의 뇌 설치. 볼트를 만들고, 야간 스크립트를 넣고, Claude Code 지침과 권한을 맞추고,
  매일 03:00 작업을 등록한다. 여러 번 실행해도 된다 (있는 노트는 덮지 않고, 지침은 같은 자리만 바꾼다).
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -VaultPath "D:\Notes\SeventhBrain"
.NOTES
  Windows PowerShell 5.1 기준. 이 파일과 scripts\*.ps1은 UTF-8 with BOM으로 저장한다.
#>
[CmdletBinding()]
param(
  [string]$VaultPath = (Join-Path $env:USERPROFILE 'SeventhBrain'),
  [string]$OrcaRoot = (Join-Path $env:USERPROFILE 'orca'),
  [string]$ClaudeHome = (Join-Path $env:USERPROFILE '.claude'),
  [string]$CodexHome = $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }),
  [ValidateSet('', 'claude', 'codex')][string]$NightEngine = '',   # 비우면 Claude Code가 있으면 Claude, 없으면 Codex
  [string]$CodexModel = '',
  [string]$HermesModel = 'hermes3:8b',
  [string]$ClaudeModel = 'claude-opus-5-5',
  [string]$ClaudeFallbackModel = 'claude-sonnet-5-5',
  [switch]$SkipPersonaEdit,     # persona.md를 메모장으로 열지 않는다
  [switch]$SkipClaudeConfig,    # ~/.claude/CLAUDE.md 와 settings.json 을 건드리지 않는다
  [switch]$SkipWorkspaceFiles,  # Orca 워크스페이스 폴더에 CLAUDE.md 를 만들지 않는다
  [switch]$SkipSchedule         # 작업 스케줄러에 등록하지 않는다
)

$ErrorActionPreference = 'Stop'
$Kit     = $PSScriptRoot
$Utf8    = New-Object System.Text.UTF8Encoding($false)
$Utf8Bom = New-Object System.Text.UTF8Encoding($true)
$Start   = '<!-- seventh-brain:start'
$End     = '<!-- seventh-brain:end -->'
$Today   = Get-Date -Format 'yyyy-MM-dd'

function Say([string]$m) { Write-Host $m }
function Warn([string]$m) { Write-Host ('   [주의] ' + $m) -ForegroundColor Yellow }
function Read-Text([string]$p) {
  $t = [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8)
  if ($t.Length -gt 0 -and $t[0] -eq [char]0xFEFF) { $t = $t.Substring(1) }
  return $t
}
function Write-Text([string]$p, [string]$t, $enc) {
  $d = Split-Path -Parent $p
  if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
  [System.IO.File]::WriteAllText($p, $t, $enc)
}
function Backup([string]$p) {
  if (Test-Path -LiteralPath $p) {
    $b = $p + '.bak-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
    Copy-Item -LiteralPath $p -Destination $b
    Say ('   백업: ' + $b)
  }
}
# Replace the managed block in a file, or append it when the file has none.
function Set-Block([string]$file, [string]$block) {
  $nl = "`r`n"
  if (Test-Path -LiteralPath $file) {
    $t = Read-Text $file
    $i = $t.IndexOf($Start); $j = $t.IndexOf($End)
    if ($i -ge 0 -and $j -gt $i) {
      $new = $t.Substring(0, $i) + $block.Trim() + $t.Substring($j + $End.Length)
    } else {
      $new = $t.TrimEnd() + $nl + $nl + $block.Trim() + $nl
    }
    if ($new -ne $t) { Backup $file; Write-Text $file $new $Utf8 }
  } else {
    Write-Text $file ($block.Trim() + $nl) $Utf8
  }
}
# C:\Users\me\vault -> //c/Users/me/vault  (Claude Code permission rule form for Windows absolute paths)
function To-RulePath([string]$p) {
  $f = [System.IO.Path]::GetFullPath($p).TrimEnd('\')
  return '//' + $f.Substring(0, 1).ToLowerInvariant() + ($f.Substring(2) -replace '\\', '/')
}
# C:\Users\me\orca -> C--Users-me-orca  (how Claude Code names transcript folders)
function To-ProjectKey([string]$p) { return ([System.IO.Path]::GetFullPath($p).TrimEnd('\') -replace '[^A-Za-z0-9]', '-') }

$VaultPath = [System.IO.Path]::GetFullPath($VaultPath).TrimEnd('\')
$OrcaRoot  = [System.IO.Path]::GetFullPath($OrcaRoot).TrimEnd('\')
Say ''
Say '제7의 뇌 설치'
Say ('  볼트: ' + $VaultPath)
Say ('  Orca: ' + $OrcaRoot)
Say ''

# 0. Check what the nightly run needs. Missing pieces are warnings, not stops.
Say '0. 필요한 것 확인'
try {
  $tags = Invoke-RestMethod -Uri 'http://localhost:11434/api/tags' -TimeoutSec 5
  if (@($tags.models | ForEach-Object { $_.name }) -contains $HermesModel) { Say ('   Ollama와 ' + $HermesModel + ' 확인') }
  else { Warn ('Ollama에 ' + $HermesModel + ' 모델이 없다. 실행: ollama pull ' + $HermesModel) }
} catch { Warn ('Ollama가 응답하지 않는다. https://ollama.com 에서 설치한 뒤 실행: ollama pull ' + $HermesModel) }
$hasClaude = [bool](Get-Command claude -ErrorAction SilentlyContinue)
$hasCodex  = [bool](Get-Command codex -ErrorAction SilentlyContinue)
if ($hasClaude) { Say '   Claude Code 확인' }
if ($hasCodex)  { Say '   Codex 확인' }
if (-not $hasClaude -and -not $hasCodex) { Warn 'claude도 codex도 없다. 둘 중 하나를 설치하고 로그인한다 (README 참고).' }
$engine = if ($NightEngine) { $NightEngine } elseif ($hasClaude) { 'claude' } elseif ($hasCodex) { 'codex' } else { '' }
if ($engine -eq 'codex') { Warn '밤 정리를 Codex로 돌린다. Codex는 폴더별 읽기 차단이 없어 99_Private 보호가 지시문에만 기댄다. 민감한 기록은 볼트 밖에 두는 것이 안전하다 (README 참고).' }
if (Test-Path -LiteralPath (Join-Path $OrcaRoot 'workspaces')) { Say '   Orca 폴더 확인' }
else { Warn ('Orca 폴더가 없다: ' + $OrcaRoot + '. 다른 곳이면 -OrcaRoot 로 지정한다.') }

# 1. Persona: the user writes it in Notepad, it goes into the global instructions.
Say ''
Say '1. 페르소나'
$personaFile = Join-Path $Kit 'persona.md'
if (-not $SkipPersonaEdit -and -not $SkipClaudeConfig) {
  Say '   메모장에서 persona.md를 고치고 저장한 뒤, 메모장을 닫으면 설치가 이어진다.'
  Start-Process -FilePath 'notepad.exe' -ArgumentList ('"' + $personaFile + '"') -Wait
}
$persona = ([regex]::Replace((Read-Text $personaFile), '(?s)<!--.*?-->', '')).Trim()
if ($persona -match '\(여기에 분야를 적는다') { Warn 'persona.md의 역할 부분이 아직 예시 문구 그대로다. 나중에 고치고 다시 실행해도 된다.' }

# 2. Vault: folders and starter notes. Existing files are never overwritten.
Say ''
Say '2. 볼트'
foreach ($d in '00_Inbox', '01_Projects', '02_Notes', '03_Daily', '04_References', '99_Private', '_attachments', '90_Meta\scripts') {
  New-Item -ItemType Directory -Force -Path (Join-Path $VaultPath $d) | Out-Null
}
$tpl = Join-Path $Kit 'vault-template'
$added = 0
foreach ($f in Get-ChildItem -LiteralPath $tpl -Recurse -File -Force) {
  $rel = $f.FullName.Substring($tpl.Length).TrimStart('\')
  $to = Join-Path $VaultPath $rel
  if (-not (Test-Path -LiteralPath $to)) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $to) | Out-Null
    Copy-Item -LiteralPath $f.FullName -Destination $to; $added++
  }
}
Say ('   기본 노트 ' + $added + '개 추가 (이미 있는 파일은 그대로 둠)')

# 3. Scripts and config.json.
Say ''
Say '3. 야간 스크립트'
$scriptDir = Join-Path $VaultPath '90_Meta\scripts'
foreach ($f in Get-ChildItem -LiteralPath (Join-Path $Kit 'scripts') -File) {
  $to = Join-Path $scriptDir $f.Name
  if ($f.Name -eq 'gardener-prompt.md' -and (Test-Path -LiteralPath $to) -and ((Read-Text $to) -ne (Read-Text $f.FullName))) { Backup $to }
  Copy-Item -LiteralPath $f.FullName -Destination $to -Force
}
$config = [ordered]@{
  vaultPath           = $VaultPath
  orcaRoot            = $OrcaRoot
  claudeProjects      = (Join-Path $ClaudeHome 'projects')
  dirFilter           = ((To-ProjectKey $OrcaRoot) + '-*')
  hermesModel         = $HermesModel
  nightEngine         = $engine
  claudeModel         = $ClaudeModel
  claudeFallbackModel = $ClaudeFallbackModel
  codexModel          = $CodexModel
  syncPrefsToClaude   = ($VaultPath -match '\s')   # Claude's @import cannot take a path with spaces; copy instead
}
Write-Text (Join-Path $scriptDir 'config.json') (($config | ConvertTo-Json) + "`r`n") $Utf8
Say ('   ' + $scriptDir + ' 에 스크립트와 config.json')

# 4. Global Claude Code instructions: persona + how to leave notes in the vault.
Say ''
Say '4. Claude Code 전역 지침'
if ($SkipClaudeConfig) { Say '   건너뜀 (-SkipClaudeConfig)' } else {
  $block = (Read-Text (Join-Path $Kit 'instructions\global-claude.md')).Replace('{{PERSONA}}', $persona).Replace('{{VAULT}}', $VaultPath).Replace('{{ORCA}}', $OrcaRoot)
  # Claude Code loads the preference note itself through an @import line; Codex gets a nightly copy.
  $prefsPath = (Join-Path $VaultPath '02_Notes\작업-선호.md') -replace '\\', '/'
  $claudeImport = if ($config.syncPrefsToClaude) { '(볼트 경로에 공백이 있어, 이 노트는 밤마다 이 파일 아래 구역에 복사된다)' } else { "`r`n@" + $prefsPath }
  if ($hasClaude -or (Test-Path -LiteralPath $ClaudeHome)) {
    Set-Block (Join-Path $ClaudeHome 'CLAUDE.md') $block.Replace('{{PREFS_IMPORT}}', $claudeImport)
    Say ('   Claude Code: ' + (Join-Path $ClaudeHome 'CLAUDE.md'))
  }
  if ($hasCodex -or (Test-Path -LiteralPath $CodexHome)) {
    Set-Block (Join-Path $CodexHome 'AGENTS.md') $block.Replace('{{PREFS_IMPORT}}', '(이 노트는 밤마다 이 파일 아래 구역에 복사된다)')
    Say ('   Codex: ' + (Join-Path $CodexHome 'AGENTS.md'))
  }
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptDir 'sync-prefs.ps1') -CodexHome $CodexHome -ClaudeHome $ClaudeHome | ForEach-Object { '   ' + ($_ -replace '^\S+ \S+\s+\[prefs\] ', '작업 선호: ') }
}

# 5. Orca workspaces: each project's sessions read its first page before working.
Say ''
Say '5. Orca 프로젝트 연결'
$wsRoot = Join-Path $OrcaRoot 'workspaces'
if ($SkipWorkspaceFiles) { Say '   건너뜀 (-SkipWorkspaceFiles)' }
elseif (-not (Test-Path -LiteralPath $wsRoot)) { Say '   Orca 워크스페이스 폴더가 없어 건너뜀' }
else {
  $wsTpl = Read-Text (Join-Path $Kit 'instructions\workspace-claude.md')
  foreach ($p in Get-ChildItem -LiteralPath $wsRoot -Directory) {
    $proj = $p.Name
    Set-Block (Join-Path $p.FullName 'CLAUDE.md') ($wsTpl.Replace('{{PROJECT}}', $proj).Replace('{{VAULT}}', $VaultPath))
    $hub = Join-Path $VaultPath ('01_Projects\' + $proj + '\_index.md')
    $named = @(Get-ChildItem -LiteralPath (Join-Path $VaultPath '01_Projects') -Recurse -Filter '_index.md' -File -ErrorAction SilentlyContinue |
      Where-Object { (Read-Text $_.FullName) -match ('(?m)^tags:.*\b' + [regex]::Escape($proj) + '\b') })
    if (-not (Test-Path -LiteralPath $hub) -and $named.Count -eq 0) {
      $tag = ($proj -replace '[^\w-]', '-')
      $h = "---`r`ntags: [project, $tag]`r`nstatus: active`r`nsource: claude`r`ncreated: $Today`r`nupdated: $Today`r`n---`r`n`r`n# $proj`r`n`r`nOrca 프로젝트 $proj 의 첫 페이지. 이 프로젝트의 목적을 한두 줄로 적어 두면 작업 세션이 먼저 읽는다. tags의 $tag 는 작업 기록이 이 폴더를 찾는 표시라 지우지 않는다.`r`n`r`n## 결정 기록`r`n`r`n## 주제 (자동 갱신)`r`n<!-- auto:topics:start -->`r`n<!-- auto:topics:end -->`r`n`r`n## 최근 진행 (자동 갱신)`r`n<!-- auto:recent:start -->`r`n<!-- auto:recent:end -->`r`n"
      Write-Text $hub $h $Utf8
    }
    Say ('   ' + $proj)
  }
}

# 6. Claude Code permissions: read the vault, write decision records, never touch 99_Private.
Say ''
Say '6. Claude Code 권한'
if ($SkipClaudeConfig) { Say '   건너뜀 (-SkipClaudeConfig)' } else {
  if (-not ($hasClaude -or (Test-Path -LiteralPath $ClaudeHome))) { Say '   Claude Code가 없어 건너뜀' } else {
  $settingsFile = Join-Path $ClaudeHome 'settings.json'
  $rv = To-RulePath $VaultPath
  $want = @{
    allow = @("Read($rv/**)", "Edit($rv/01_Projects/*/decisions/**)", "Edit($rv/01_Projects/*/*/decisions/**)")
    deny  = @("Read($rv/99_Private/**)", "Edit($rv/99_Private/**)")
  }
  $s = if (Test-Path -LiteralPath $settingsFile) { (Read-Text $settingsFile) | ConvertFrom-Json } else { New-Object psobject }
  if (-not ($s.PSObject.Properties.Name -contains 'permissions')) { $s | Add-Member -NotePropertyName permissions -NotePropertyValue (New-Object psobject) }
  $changed = $false
  foreach ($kind in 'allow', 'deny') {
    if (-not ($s.permissions.PSObject.Properties.Name -contains $kind)) { $s.permissions | Add-Member -NotePropertyName $kind -NotePropertyValue @() }
    $have = @($s.permissions.$kind)
    $more = @($want[$kind] | Where-Object { $have -notcontains $_ })
    if ($more.Count -gt 0) { $s.permissions.$kind = @($have + $more); $changed = $true }
  }
  if ($changed) {
    Backup $settingsFile
    Write-Text $settingsFile (($s | ConvertTo-Json -Depth 50) + "`r`n") $Utf8
    Say ('   ' + $settingsFile + ' 에 볼트 규칙 추가')
  } else { Say '   이미 들어 있음' }
  }
  if ($hasCodex) { Say ('   Codex: 개발 세션에서 결정 기록을 볼트에 쓰려면 codex를 --add-dir "' + $VaultPath + '" 로 띄우거나 README의 writable_roots 설정을 쓴다.') }
}

# 7. Daily 03:00 task.
Say ''
Say '7. 매일 03:00 작업'
if ($SkipSchedule) { Say '   건너뜀 (-SkipSchedule)' }
else { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $scriptDir 'register-task.ps1') }

Say ''
Say '끝. 다음 할 일:'
Say ('  1) Obsidian에서 "폴더를 볼트로 열기"로 ' + $VaultPath + ' 를 연다.')
Say '  2) Obsidian 설정 > 코어 플러그인에서 "데일리 노트"와 "템플릿"을 켠다.'
Say '  3) 평소처럼 Orca에서 Claude Code로 일한다. 다음 날 아침 03_Daily 의 데일리 노트를 본다.'
Say ('  지금 한 번 돌려 보려면: Start-ScheduledTask -TaskName Hermes-Inbox-Nightly  (로그: ' + (Join-Path $scriptDir 'hermes-inbox.log') + ')')
