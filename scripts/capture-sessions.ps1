<#
.SYNOPSIS
  Capture recent Claude Code work sessions into the vault, organized like Orca, using local Hermes.
.DESCRIPTION
  Major topic = the Orca project the session ran in, read from the transcript's working
  directory (<Orca>\workspaces\<project>\<worktree> or ...\projects\<project>),
  so it is exact, not guessed. Minor topic = a content keyword inside that project: after a
  summary call, a second, schema-constrained Hermes call picks one of the project's topic
  notes (01_Projects/<project>/<topic>.md, tag 주제, with a one-line description) or "새 주제",
  which triggers a naming call. A new topic from a worktree that already has notes is folded
  into that worktree's usual topic, so one line of work does not split into many folders.
  Output: 01_Projects/<project>/log/<topic>/<title>.md, written like a short work log: the
  result on top, then what was done and how, then what is left; the source sits folded at
  the bottom. No H1 (Obsidian already shows the file name as the title) and no date in the
  body or the file name: the date lives only in the frontmatter (updated).
  Stable names: a note is found again by its session marker, and its folder and file name
  are kept when the session is captured again, also after a manual move or rename inside
  the log folder. Only the part above the marker is rewritten; text written below it is kept.
  Notes from the older "<date> <title>" scheme keep their topic folder and get a new name once.
  When two sessions would share a title, Hermes is asked once for a name that shows the
  difference. Forked or resumed sessions copy the earlier messages (marked forkedFrom in the
  transcript); only the messages a session added itself are summarized, and its note links
  the note of the session it came from. Orca's helper sessions that only name a git branch
  leave no note. A state file re-captures only changed sessions. Empty summaries are
  skipped. All model calls stay on localhost.
.NOTES
  num_ctx must be large: Ollama defaults to a small context that silently truncates long
  Korean inputs and returns empty JSON. The log shows the input tokens of each summary and
  warns when they get near num_ctx. A short session is summarized in one call. A long one is
  summarized part by part (1-3 lines per part, cached by content hash in capture-cache.json,
  so a growing session only costs its new parts), and the note is then written from those
  lines alone: one call over a compressed long session made up work that never happened.
  Besides visible text, the one-line description of each command Claude ran ([작업] lines)
  is included; agentic sessions say little otherwise. The prompt has no topical example
  sentences: in testing, an example about notification sounds leaked into three unrelated
  notes. -DebugDir saves each final prompt and raw answer for tuning.
  Save this file as UTF-8 with BOM (PowerShell 5.1).
  Do not pass [pscustomobject]@{...} straight into a .NET method call in PowerShell 5.1: it
  arrives as a wrapped hashtable and property access throws "Argument types do not match".
#>

[CmdletBinding()]
param(
  [string]$ProjectsBase = '',
  [string]$OrcaRoot = '',
  [string]$DirFilter = '*',          # transcript folders to scan; the Orca project list decides what is kept
  [string]$VaultPath = '',
  [string]$Model = '',
  [string]$ApiBase = 'http://localhost:11434',
  [int]$SinceHours = 168,
  [int]$NumCtx = 16384,
  [int]$SingleMax = 7000,      # sessions up to this many characters are summarized in one call
  [int]$ChunkChars = 5000,     # longer ones part by part, about this many characters per part
  [string]$DebugDir = ''       # if set, each session's final prompt and raw answer are saved here
)

$ErrorActionPreference = 'Stop'
# Settings written by install.ps1 (read here: param defaults cannot see the script folder in PowerShell 5.1).
$KitConfig = $null
try { $KitConfig = Get-Content -LiteralPath (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
if ($KitConfig) {
  if (-not $ProjectsBase) { $ProjectsBase = [string]$KitConfig.claudeProjects }
  if (-not $OrcaRoot) { $OrcaRoot = [string]$KitConfig.orcaRoot }
  if (-not $VaultPath) { $VaultPath = [string]$KitConfig.vaultPath }
  if (-not $Model) { $Model = [string]$KitConfig.hermesModel }
}
if (-not $VaultPath -or -not (Test-Path -LiteralPath $VaultPath)) { throw 'config.json is missing or vaultPath is wrong. Run install.ps1 first.' }
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogPath   = Join-Path $ScriptDir 'hermes-inbox.log'
$StateFile = Join-Path $ScriptDir 'capture-state.json'
$CacheFile = Join-Path $ScriptDir 'capture-cache.json'   # part summaries of long sessions, by content hash
$ProjRoot  = Join-Path $VaultPath '01_Projects'
$Unfiled   = '_미분류'
$NewLabel  = '새 주제'
$ProjDirs  = @{}   # Orca project id or name -> vault folder (see Get-ProjectDir)
# Orca's project list (orca-map.ps1). Without it only sessions under OrcaRoot are captured.
$OrcaProjects = @()
$OrcaMapFile = Join-Path $ScriptDir 'orca-projects.json'
if (Test-Path -LiteralPath $OrcaMapFile) { try { $OrcaProjects = @((Get-Content -LiteralPath $OrcaMapFile -Raw -Encoding UTF8 | ConvertFrom-Json).projects) } catch { } }
$genUri    = "$ApiBase/api/generate"

# Field order matters to a small model: the title is written after it has summed up the work.
$SummarySchema = @{
  type = 'object'
  properties = [ordered]@{
    what   = @{ type = 'string' }
    how    = @{ type = 'array'; items = @{ type = 'string' } }
    result = @{ type = 'string' }
    title  = @{ type = 'string' }
    next   = @{ type = 'array'; items = @{ type = 'string' } }
  }
  required = @('what', 'how', 'result', 'title', 'next')
}
$TitleSchema = @{ type = 'object'; properties = @{ title = @{ type = 'string' } }; required = @('title') }
# Nouns that end a work-log line ("설치" -> "설치했다", todo "설치" -> "설치하기").
$ActionNouns = '생성|설치|변경|설정|추가|삭제|수정|확인|작성|적용|구축|정리|실행|완료|테스트|분류|저장|이동|등록|도입|커밋|표현|연결|검토|개선|구현|정의|기록|공유|반영|검증|측정|비교|분석|업데이트|배포|백업|점검|조사|대응|리뷰'
# Filler a small model adds when it has nothing concrete to say.
$buzz   = '활용한|활용해|효율|극대화|최적화|통합 관리|생산성 향상'
$buzzR  = '향상되|높아졌|효율|생산성|극대화|최적화|답변이 제공|개선되었|명확해졌'
$fluff  = '요청을 (이해|분석|파악)|키워드와 목표|답변(을|이) 제공|아이디어가 제시|생각을 나열'
$hedge  = '필요하다면|필요한 경우|필요에 따라|만약|있다면|고려하기|사용성|편의성|수 있(다|음)\.?$|(음|함|됨)\.?$'
$cmdRx  = '^(git|npm|npx|pip|cd|curl|winget|ollama|claude|powershell|python)\s'
$codeRx = '\$\{|\$[A-Za-z_]|%\{|[{}]|</?[A-Za-z][\w-]*>'   # code or markup copied from the transcript ("$0.26" is fine)
$cutRx  = '(을|를|의|와|과|에|로|및|,)$'                  # a line cut off mid-sentence
$fileOnly = '^(파일 수정:|\S+\s+파일\s+수정했다\.?$)'      # "파일 수정: x.md" says only which file, not what changed
$MapSchema = @{
  type = 'object'
  properties = [ordered]@{ done = @{ type = 'array'; items = @{ type = 'string' } }; next = @{ type = 'array'; items = @{ type = 'string' } } }
  required = @('done', 'next')
}

# ---- Prompt text shared by the one-call and the part-by-part summaries ----
$ActNote = '[작업] 줄은 Claude가 실제로 실행한 명령이나 고친 파일을 한 줄로 적은 것이다 (영어일 수 있다). 그대로 옮기지 말고 무엇을 했는지 한국어로 풀어 쓴다.'
$Rules = @'
쓰는 법:
- 대화에 실제로 나온 일만 쓴다. 지어내거나 일반론을 붙이지 않는다.
- 질문과 설명만 오갔다면 무엇을 물었고 어떤 답을 얻었는지 쓴다. 하지 않은 일을 한 것처럼 쓰지 않는다.
- 긍정문으로 쓴다. 실제로 한 일, 확인한 것, 정한 것을 그대로 적고, 미룬 일은 "~는 다음으로 미뤘다", "~는 보류했다"처럼 정한 내용으로 적는다. "~한 것은 아니다", "~하지 않았다", "~하기 어렵다" 꼴은 쓰지 않는다.
- 작업 일지처럼 짧은 평서문으로 쓰고 "~했다", "~하기로 했다"처럼 끝낸다. "설정 변경" 같은 명사 조각이나 "~습니다", "~음", "~함"으로 끝내지 않는다.
- 무엇을 어떤 값이나 방법으로 바꿨는지 구체적으로 쓴다. "효율", "향상", "최적화", "통합", "관리", "활용" 같은 뻔한 말은 쓰지 않는다.
- "사용자가"로 문장을 시작하지 않는다. 사용자의 말을 그대로 옮기지 않는다.
- 고유명사(Claude, Hermes, Orca, Obsidian, Ollama, Opus 등)는 영어로 쓴다. Claude를 "클라우드"로 쓰지 않는다.
- 명령어, URL, 커밋 해시, 파일 경로, 세션 ID, HTML 주석은 쓰지 않는다.
'@
$FieldsOne = @'
항목:
- what: 무엇을 하려 했는지 한 문장. 이유가 보이면 함께 쓴다.
- how: 실제로 어떻게 했는지 2-4개. 한 항목에 한 단계만 쓴다.
- result: 그래서 무엇이 달라졌는지, 또는 무엇을 정했는지 한 문장.
- title: 무슨 일이었는지 알 수 있는 짧은 이름, 20자 안팎. 문장이 아니라 "~하기"나 명사로 끝나는 이름으로 쓴다. "완료", "진행"은 붙이지 않는다.
- next: 대화에서 남았다고 분명히 나온 일만 0-3개, "~하기"로 끝낸다. 없으면 빈 배열로 둔다.

JSON 객체 하나만 출력한다. 코드펜스나 설명은 쓰지 않는다.
{"what": "", "how": [], "result": "", "title": "", "next": []}
'@
$ManySchema = @{
  type = 'object'
  properties = [ordered]@{
    what   = @{ type = 'string' }
    how    = @{ type = 'array'; items = @{ type = 'integer' } }   # picked by number: an 8B model rewriting 50 lines blurred them into "파일 수정했다"
    result = @{ type = 'string' }
    title  = @{ type = 'string' }
    next   = @{ type = 'array'; items = @{ type = 'string' } }
  }
  required = @('what', 'how', 'result', 'title', 'next')
}
$FieldsMany = @'
항목:
- what: 이 대화에서 하려던 일 한 문장.
- how: 목록에서 이 대화의 가장 중요한 일을 3-5개 고른다. 문장을 새로 쓰지 말고 그 번호만 숫자 배열로 쓴다.
- result: 결국 무엇이 달라졌는지, 또는 무엇을 정했는지 한 문장.
- title: 대화 전체를 알 수 있는 짧은 이름, 20자 안팎. 문장이 아니라 "~하기"나 명사로 끝나는 이름으로 쓴다. "완료", "진행"은 붙이지 않는다.
- next: 남은 일 후보 가운데 아직 남은 것만 0-3개, "~하기"로 끝낸다. 없으면 빈 배열로 둔다.

JSON 객체 하나만 출력한다. 코드펜스나 설명은 쓰지 않는다.
{"what": "", "how": [], "result": "", "title": "", "next": []}
'@

function Write-Log([string]$msg) {
  $line = '{0}  [capture] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $msg
  try { Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8 } catch { }
  Write-Output $line
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
function Fix-Names([string]$s) {
  # Undo transliterated proper nouns; "클라우드" is only Claude when it sits with the other tools.
  if (-not $s) { return $s }
  $tools = ($s -match 'Hermes|Obsidian|Orca|Claude|스킬|goalplz|헤르메스|옵시디언|오르카|클로드')   # judged on the text as written
  $s = $s -replace '헤르메스', 'Hermes' -replace '옵시디언', 'Obsidian' -replace '오르카', 'Orca' -replace '오푸스', 'Opus' -replace '올라마', 'Ollama' -replace '클로드', 'Claude'
  $s = $s -replace '클라우드\s?코드', 'Claude Code'
  # "클라우드가 정리했다": as the one acting it is Claude; "클라우드에서" (a place) stays cloud.
  $s = [regex]::Replace($s, '클라우드(?=(가|는|를|와|과|에게|한테|의|도)(\s|$|[,.]))', 'Claude')
  if ($tools) { $s = $s -replace '클라우드', 'Claude' }
  # Lowercase tool names written as words ("orca 테마"); "orca-theme" and "hermes3:8b" stay as they are.
  foreach ($nm in 'Orca', 'Claude', 'Obsidian', 'Hermes', 'Ollama') { $s = [regex]::Replace($s, '(?<![\w\-/.])' + $nm.ToLowerInvariant() + '(?![\w\-:/.])', $nm) }
  return $s
}
function Join-And([string]$s) {
  # Written-report "A 및 B" -> plain "A와 B" / "A과 B" (by the final consonant), else "A, B".
  return [regex]::Replace($s, '(\S)\s+및\s+', [System.Text.RegularExpressions.MatchEvaluator]{
    param($m)
    $ch = $m.Groups[1].Value; $c = [int][char]$ch
    if ($c -ge 0xAC00 -and $c -le 0xD7A3) { if ((($c - 0xAC00) % 28) -eq 0) { return $ch + '와 ' } else { return $ch + '과 ' } }
    return $ch + ', '
  })
}
function Get-Dice([string]$a, [string]$b) {
  # Character-bigram overlap (0-1), to spot a "what" line that only repeats the result.
  $a = $a -replace '[\s\.,]', ''; $b = $b -replace '[\s\.,]', ''
  if ($a.Length -lt 2 -or $b.Length -lt 2) { return 0 }
  $ga = @{}; for ($i = 0; $i -lt $a.Length - 1; $i++) { $g = $a.Substring($i, 2); $ga[$g] = 1 + [int]$ga[$g] }
  $hit = 0; for ($i = 0; $i -lt $b.Length - 1; $i++) { $g = $b.Substring($i, 2); if ([int]$ga[$g] -gt 0) { $ga[$g]--; $hit++ } }
  return (2.0 * $hit) / (($a.Length - 1) + ($b.Length - 1))
}
function Clean-Turn([string]$t) {
  # Visible conversation only: harness wrappers, notices and the compaction summary are not part of it.
  if (-not $t) { return '' }
  $t = [regex]::Replace($t, '(?s)<system-reminder>.*?</system-reminder>', '')
  $t = [regex]::Replace($t, '(?s)<(task-notification|local-command-caveat|local-command-stdout|local-command-stderr)>.*?</\1>', '')
  $t = [regex]::Replace($t, '(?s)<command-message>.*?</command-message>', '')
  $t = [regex]::Replace($t, '(?s)<command-name>(.*?)</command-name>\s*(?:<command-args>(.*?)</command-args>)?', '$1 $2')
  # A trailing "interrupted" once turned a finished install into "request cancelled".
  $t = [regex]::Replace($t, '(?m)^\[Request interrupted by user[^\]]*\]\s*$', '')
  $t = $t.Trim()
  if ($t.StartsWith('This session is being continued from a previous conversation')) { return '' }
  return $t
}
function Fix-Style([string]$s) {
  # Plain diary register ("~했다"), no comment markers or quoted names leaking into the text.
  if (-not $s) { return $s }
  $s = [regex]::Replace($s, '\s*<!--.*?-->', '')
  $s = [regex]::Replace($s, 'https?://\S+', '')
  $s = [regex]::Replace($s, '[A-Za-z]:\\[^\s,)]+', '')                                         # absolute paths
  $s = [regex]::Replace($s, '[^\s,()"]*[\\/][^\s,()"]*\.(md|ps1|json|jsonl|txt|py|js|ts)\b', '')  # relative paths
  # Code spans copied from Claude's messages read as plain words; the only code kept is the
  # protection below. Removing every backtick first keeps this idempotent: cleaning an already
  # clean line once paired the wrong backticks ("`#A3CCA3으로 ... #D6E6F5`").
  $s = $s -replace '`', ''
  # "#word" in model text would become a real Obsidian tag (even #정리해줘): keep it as code.
  # Colors first, so "#A3CCA3으로" becomes "`#A3CCA3`으로", not one code span with the particle.
  $s = [regex]::Replace($s, '(?<![\w&])#([0-9A-Fa-f]{6}|[0-9A-Fa-f]{3})(?![0-9A-Za-z])', '`#$1`')
  $s = [regex]::Replace($s, '(?<![`\w&])#([^\s#`,.;:!?()\[\]{}]+)', '`#$1`')
  $s = Join-And $s
  $s = [regex]::Replace($s, "'([A-Za-z0-9 #._+-]+)'", '$1')
  $s = [regex]::Replace($s, "'([^'\r\n]{1,40})'", '"$1"')
  $s = [regex]::Replace($s, '(필요|중요|가능|불가능|충분|부족|유용|적합|동일|유사|정확|명확|간단|복잡|편리|안전)합니다', '$1하다')
  $s = $s -replace '합니다', '한다' -replace '됩니다', '된다' -replace '입니다', '이다' -replace '습니다', '다'
  return ($s -replace '\s+', ' ').Trim()
}
function Fix-Ending([string]$s) {
  # Work-log sentences end in "~했다": only "안 함" and known action nouns are rewritten (never "포함" etc).
  if (-not $s) { return $s }
  $s = $s -replace '안 함\.?$', '안 한다.'
  $s = [regex]::Replace($s, '(었|았|였|했|됐|있|없)음\.?$', '$1다.')   # "변경되었음" -> "변경되었다."
  $s = $s -replace '됨\.?$', '됐다.'
  $s = $s -replace '하기\.?$', '했다.'
  $s = [regex]::Replace($s, "($ActionNouns)함?\.?$", '$1했다.')
  return $s
}
function To-Todo([string]$s) {
  # Checklist form: "X하는 것이 필요하다" / "X해야 한다" / "X한다" -> "X하기".
  $s = Fix-Style $s
  $m = [regex]::Match($s, '^(.*\S)는 것이 (필요|좋|바람직)\S*\s*\.?$')
  if ($m.Success) { return $m.Groups[1].Value + '기' }
  $s = $s -replace '하기로 했다\.?$', '하기' -replace '해야 한다\.?$', '하기' -replace '할 필요가 있다\.?$', '하기' -replace '할 것\.?$', '하기'
  $s = $s -replace '해\s?보자\.?$', '해 보기' -replace '하자\.?$', '하기' -replace '한다\.?$', '하기'
  $s = $s -replace '\s?보(십시오|세요)\.?$', ' 보기' -replace '(하십시오|하세요|해 주세요|해주세요)\.?$', '하기'
  $s = [regex]::Replace($s, "($ActionNouns)함?\.?$", '$1하기')
  # "붙일 계획이다" -> "붙이기", "진행할 계획이다" -> "진행하기": drop the verb's final ㄹ, add 기.
  $s = [regex]::Replace(($s -replace '\.$', ''), '([가-힣])\s+계획이다$', [System.Text.RegularExpressions.MatchEvaluator]{
    param($m)
    $c = [int][char]$m.Groups[1].Value
    if ((($c - 0xAC00) % 28) -eq 8) { return [string][char]($c - 8) + '기' }
    return $m.Groups[1].Value + '기'
  })
  # Polite "맞춥니다" -> "맞추기": drop the final ㅂ before 니다, add 기.
  $s = [regex]::Replace(($s -replace '\.$', ''), '([가-힣])니다$', [System.Text.RegularExpressions.MatchEvaluator]{
    param($m)
    $c = [int][char]$m.Groups[1].Value
    if ((($c - 0xAC00) % 28) -eq 17) { return [string][char]($c - 17) + '기' }
    return $m.Value
  })
  # Dictionary form "붙이다" -> "붙이기"; not after a past or present ending ("했다", "간다") or "니다".
  $s = [regex]::Replace(($s -replace '\.$', ''), '([가-힣])다$', [System.Text.RegularExpressions.MatchEvaluator]{
    param($m)
    $fin = ([int][char]$m.Groups[1].Value - 0xAC00) % 28
    if ($fin -eq 20 -or $fin -eq 4 -or $m.Groups[1].Value -eq '니') { return $m.Value }
    return $m.Groups[1].Value + '기'
  })
  return $s
}
function Get-Chunks($turns, [int]$size) {
  # Parts of about $size characters, cut at a user turn when possible. A boundary depends only
  # on the turns before it, so earlier parts stay byte-identical as a session grows (cacheable).
  $chunks = New-Object System.Collections.Generic.List[string]
  $cur = New-Object System.Text.StringBuilder
  foreach ($t in $turns) {
    $piece = if ($t.Length -gt 1500) { $t.Substring(0, 1500) + '...' } else { $t }
    $isUser = $t.StartsWith('[사용자]')
    if ($cur.Length -gt 0 -and (($cur.Length + $piece.Length -gt $size) -or ($isUser -and $cur.Length -gt [int]($size * 0.6)))) {
      $chunks.Add($cur.ToString()); [void]$cur.Clear()
    }
    [void]$cur.Append($piece).Append("`n`n")
  }
  if ($cur.Length -gt 0) { $chunks.Add($cur.ToString()) }
  return ,$chunks
}
function Get-Hash([string]$s) {
  $sha = [System.Security.Cryptography.SHA1]::Create()
  $b = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($s))
  return ([System.BitConverter]::ToString($b) -replace '-', '').Substring(0, 16)
}
function Clean-Lines($arr) {
  # Model lines -> plain Korean sentences: names fixed, copied "[작업]" labels and English-only,
  # code, command or template lines dropped. Endings are fixed by the caller (done vs todo).
  # Names first, so "클라우드가 ..." is recognized as the redundant subject "Claude가".
  @(@($arr) | ForEach-Object {
      $x = Fix-Names (([string]$_).Trim())
      $x = $x -replace '^\[작업\]\s*', '' -replace '^결과적으로,?\s*', '' -replace '^이 대화에서\s*(한 일은|는)?\s*', '' -replace '^Claude(가|는|은|이)\s+', ''
      Fix-Style $x
    } |
    Where-Object { $_ -and (Get-HangulShare $_) -ge 0.2 -and $_ -notmatch $codeRx -and $_ -notmatch $cmdRx -and $_ -notmatch $fileOnly -and -not (Is-Echo $_) })
}
function Get-HangulShare([string]$s) {
  # Share of Hangul among the visible characters: a mostly English line is a copied label, not a sentence.
  $v = ($s -replace '\s', '').Length
  if ($v -eq 0) { return 0 }
  return ([regex]::Matches($s, '[가-힣]').Count / $v)
}
function Fix-Title([string]$s) {
  # A title names the work: no report words ("완료", "진행"), no sentence ending, no period.
  $s = Fix-Style (Fix-Names (([string]$s).Trim()))
  if (-not $s) { return '' }
  $s = $s -replace '`', '' -replace '^\s*세션\s*(핵심\s*)?요약\s*[:\-]?\s*', '' -replace '\.$', ''
  $s = [regex]::Replace($s, '(?<=[가-힣])-|-(?=[가-힣])', ' ')   # "설치-가이드" -> "설치 가이드"
  $s = $s -replace '\s*(완료|진행|수행|성공)(했다|함|됨)?$', ''
  $s = $s -replace '(했다|한다)$', '하기'
  return ($s -replace '\s+', ' ').Trim()
}
function Is-Echo([string]$s) {
  # Template echo, also when the model copies only the start of an example; pure punctuation is junk too.
  if (-not $s) { return $false }
  $t = $s -replace '[\s\.,]', ''
  if ($t -eq '') { return $true }
  foreach ($e in $echo) {
    $k = $e -replace '[\s\.,]', ''
    if ($t -eq $k) { return $true }
    if ($k.Length -ge 8 -and $t.Length -ge 8 -and ($k.StartsWith($t) -or $t.StartsWith($k.Substring(0, [Math]::Min(10, $k.Length))))) { return $true }
  }
  return $false
}
function Safe-Name([string]$s, [int]$max) {
  # Valid Windows file name that keeps Obsidian wikilinks intact; long names are cut at a word boundary.
  $s = (Clean-Text $s) -replace '[\\/:*?"<>|#^\[\]]', ' ' -replace '\s+', ' '
  $s = $s.Trim().TrimEnd('.').Trim()
  if ($s.Length -gt $max) {
    $cut = $s.Substring(0, $max)
    $sp  = $cut.LastIndexOf(' ')
    if ($sp -ge [int]($max / 2)) { $cut = $cut.Substring(0, $sp) }
    $s = $cut.Trim().TrimEnd('.', ',').Trim()
  }
  return $s
}
function Write-Utf8([string]$p, [string]$t) {
  [System.IO.File]::WriteAllText($p, $t, (New-Object System.Text.UTF8Encoding($false)))
}
function Read-Utf8([string]$p) { [System.IO.File]::ReadAllText($p, [System.Text.Encoding]::UTF8) }
function Get-Frontmatter([string]$text) {
  $m = [regex]::Match($text, '(?s)^---\s*\r?\n(.*?)\r?\n---')
  if ($m.Success) { return $m.Groups[1].Value }
  return ''
}
function Invoke-Hermes([string]$prompt, $format) {
  # temperature 0 and a fixed seed: the same conversation gives the same note on every run.
  $req = @{ model = $Model; prompt = $prompt; stream = $false; format = $format; options = @{ temperature = 0; seed = 42; num_ctx = $NumCtx } } | ConvertTo-Json -Depth 10
  $r = Invoke-RestMethod -Uri $genUri -Method Post -Body ([System.Text.Encoding]::UTF8.GetBytes($req)) -ContentType 'application/json; charset=utf-8' -TimeoutSec 300
  $script:LastPromptTokens = [int]$r.prompt_eval_count
  $raw = ([string]$r.response) -replace '^\s*```(?:json)?\s*', '' -replace '\s*```\s*$', ''
  return ($raw | ConvertFrom-Json)
}
function Get-OrcaLocation([string]$cwd) {
  # Map the session's working directory to an Orca project, using Orca's own project list
  # (orca-projects.json from orca-map.ps1): the project whose folder or worktree folder contains
  # the directory, longest match first, wherever the folder is. Projects Orca keeps under
  # <OrcaRoot>\workspaces\<folder>\<worktree> also match by folder name, so worktrees Orca no
  # longer lists still land in their project.
  if (-not $cwd) { return $null }
  $c = ($cwd -replace '/', '\').TrimEnd('\')
  $best = $null; $bestLen = -1
  foreach ($p in $OrcaProjects) {
    foreach ($e in @($p.paths)) {
      $ep = ([string]$e.path).TrimEnd('\')
      if (($c -ieq $ep -or $c.StartsWith($ep + '\', [System.StringComparison]::OrdinalIgnoreCase)) -and $ep.Length -gt $bestLen) {
        $bestLen = $ep.Length
        $best = @{ Project = [string]$p.name; Worktree = [string]$e.worktree; Group = [string]$p.group; Id = [string]$p.id; Folder = [string]$p.folder; Path = [string]@($p.paths)[0].path }
      }
    }
  }
  if ($best) { return $best }
  $root = [regex]::Escape($OrcaRoot.TrimEnd('\'))
  $slug = ''; $wt = ''
  $m = [regex]::Match($c, "^$root\\workspaces\\([^\\]+)\\([^\\]+)", 'IgnoreCase')
  if ($m.Success) { $slug = $m.Groups[1].Value; $wt = $m.Groups[2].Value -replace '-', ' ' }
  else {
    $m = [regex]::Match($c, "^$root\\projects\\([^\\]+)", 'IgnoreCase')
    if ($m.Success) { $slug = $m.Groups[1].Value; $wt = '메인' }
  }
  if (-not $slug) { return $null }
  $p = @($OrcaProjects | Where-Object { $_.folder -ieq $slug }) | Select-Object -First 1
  if ($p) { return @{ Project = [string]$p.name; Worktree = $wt; Group = [string]$p.group; Id = [string]$p.id; Folder = $slug; Path = [string]@($p.paths)[0].path } }
  return @{ Project = $slug; Worktree = $wt; Group = ''; Id = ''; Folder = $slug; Path = '' }
}
function Get-Tags([string]$fm) {
  # Frontmatter tags in either form: "tags: [a, b]" or a "- a" list below "tags:".
  $m = [regex]::Match($fm, '(?m)^tags:\s*\[(.*)\]')
  if ($m.Success) { return @($m.Groups[1].Value -split ',' | ForEach-Object { $_.Trim().Trim('"').Trim("'") } | Where-Object { $_ }) }
  $m = [regex]::Match($fm, '(?m)^tags:\s*\r?\n((?:[ \t]+-[^\r\n]*\r?\n?)+)')
  if ($m.Success) { return @($m.Groups[1].Value -split '\r?\n' | ForEach-Object { ($_ -replace '^\s*-\s*', '').Trim().Trim('"').Trim("'") } | Where-Object { $_ }) }
  return @()
}
function Get-ProjectFolders {
  # Project folders: 01_Projects/<project> and, for Orca project groups, 01_Projects/<group>/<project>.
  if (-not (Test-Path -LiteralPath $ProjRoot)) { return @() }
  $top = @(Get-ChildItem -LiteralPath $ProjRoot -Directory)
  return @($top) + @($top | ForEach-Object { Get-ChildItem -LiteralPath $_.FullName -Directory | Where-Object { $_.Name -notin 'log', 'decisions', 'specs' } })
}
function Get-ProjectDir($loc) {
  # The vault folder of an Orca project: the one whose first page (_index.md) names the project in
  # an "orca:" property (Orca project id) or in its tags, so renaming or moving the folder in
  # Obsidian does not split the log. Without one, 01_Projects/<group>/<project> (or
  # 01_Projects/<project>) with a minimal first page that records the Orca id and folder.
  $key = $(if ($loc.Id) { $loc.Id } else { $loc.Project })
  if ($ProjDirs.ContainsKey($key)) { return $ProjDirs[$key] }
  $found = ''
  foreach ($d in Get-ProjectFolders) {
    $hub = Join-Path $d.FullName '_index.md'
    if (-not (Test-Path -LiteralPath $hub)) { continue }
    $fm = Get-Frontmatter (Read-Utf8 $hub)
    $orca = ([regex]::Match($fm, '(?m)^orca:\s*"?([^"\r\n]+?)"?\s*$')).Groups[1].Value
    $tags = Get-Tags $fm
    if (($loc.Id -and $orca -eq $loc.Id) -or $orca -eq $loc.Project -or $tags -contains $loc.Project -or ($loc.Folder -and $tags -contains $loc.Folder)) { $found = $d.FullName; break }
  }
  if (-not $found) {
    $name = Safe-Name $loc.Project 60
    $found = $(if ($loc.Group) { Join-Path (Join-Path $ProjRoot (Safe-Name $loc.Group 60)) $name } else { Join-Path $ProjRoot $name })
    $hub = Join-Path $found '_index.md'
    if (-not (Test-Path -LiteralPath $hub)) {
      $today = Get-Date -Format 'yyyy-MM-dd'
      $lines = @('---', 'tags: [project]', ('orca: "' + $loc.Id + '"'), ('orca_path: "' + ($loc.Path -replace '\\', '/') + '"'), 'source: claude', "created: $today", "updated: $today", '---', '',
        ('# ' + $loc.Project), '', ('Orca 프로젝트 ' + $loc.Project + '의 첫 페이지다. 이 프로젝트의 목적을 한두 줄로 적어 두면 작업 세션이 먼저 읽는다.'), '',
        '## 결정 기록', '', '## 주제 (자동 갱신)', '<!-- auto:topics:start -->', '<!-- auto:topics:end -->', '', '## 최근 진행 (자동 갱신)', '<!-- auto:recent:start -->', '<!-- auto:recent:end -->', '')
      New-Item -ItemType Directory -Force -Path $found | Out-Null
      Write-Utf8 $hub ($lines -join "`n")
      Write-Log ("     new project page: " + $hub.Substring($VaultPath.Length).TrimStart('\')) | Out-Null
    }
  }
  $ProjDirs[$key] = $found
  return $found
}
function Get-TopicRegistry([string]$projDir) {
  # Known topics of a project = its topic notes (tag 주제, with description) + its log folders.
  $reg = [ordered]@{}
  if (Test-Path -LiteralPath $projDir) {
    foreach ($file in @(Get-ChildItem -LiteralPath $projDir -Filter *.md -File)) {
      $fm = Get-Frontmatter (Read-Utf8 $file.FullName)
      if (-not $fm) { continue }
      $tagArr = Get-Tags $fm
      if ($tagArr -contains '주제') {
        $reg[$file.BaseName] = ([regex]::Match($fm, '(?m)^description:\s*(.+)$')).Groups[1].Value.Trim().Trim('"')
      }
    }
  }
  $logDir = Join-Path $projDir 'log'
  if (Test-Path -LiteralPath $logDir) {
    foreach ($d in @(Get-ChildItem -LiteralPath $logDir -Directory | Where-Object { $_.Name -notlike '_*' })) {
      if (-not $reg.Contains($d.Name)) { $reg[$d.Name] = '' }
    }
  }
  return $reg
}
function Get-Topic($reg, [string]$title, $items, [string]$worktree) {
  $names = @($reg.Keys | ForEach-Object { [string]$_ })
  $sessionText = "Orca 워크트리: $worktree`n제목: $title`n내용: " + ((@($items) | ForEach-Object { [string]$_ }) -join ' / ')
  if ($names.Count -gt 0) {
    $menu = ($names | ForEach-Object { if ($reg[$_]) { '- ' + $_ + ': ' + $reg[$_] } else { '- ' + $_ } }) -join "`n"
    $p = "다음 작업을 아래 주제 중 하나로 분류하라. 각 주제의 설명을 보고 가장 맞는 것을 고른다. 어느 주제에도 분명히 속하지 않을 때만 `"$NewLabel`"을 고른다.`n`n주제 목록:`n$menu`n- ${NewLabel}: 위 어디에도 속하지 않음`n`n작업:`n$sessionText"
    $schema = @{ type = 'object'; properties = @{ topic = @{ type = 'string'; enum = (@($names) + @($NewLabel)) } }; required = @('topic') }
    $pick = [string](Invoke-Hermes $p $schema).topic
    if ($names -contains $pick) { return $pick }
  }
  # Clearly new: ask for a short noun phrase, then fold spelling variants into a known topic.
  # The worktree line is left out here: given "Orca 워크트리: 메인", the model named topics "Orca ...".
  $contentText = "제목: $title`n내용: " + ((@($items) | ForEach-Object { [string]$_ }) -join ' / ')
  $p2 = "다음 작업이 무엇에 관한 것인지 주제어를 지어라. 2-4단어 한국어 명사구 하나만 쓴다. 작업한 내용(대상, 문제, 산출물)으로 짓고, 쓴 도구나 작업 환경 이름(Orca, Claude, Codex, 세션, 워크트리)은 넣지 않는다. 문장이나 설명은 쓰지 않는다.`n`n작업:`n$contentText"
  $schema2 = @{ type = 'object'; properties = @{ topic = @{ type = 'string' } }; required = @('topic') }
  $name = Fix-Names (([string](Invoke-Hermes $p2 $schema2).topic -replace '^\s*(새\s*주제어?|주제어?)\s*[:\uFF1A]?\s*', '').Trim())
  $name = ($name -replace '_', ' ' -replace '\s+', ' ').Trim()
  $name = ($name -replace '^(?i)(orca|claude|codex)\s+', '').Trim()     # tool names are not topics
  $w = @($name -split ' ' | Where-Object { $_ }); if ($w.Count -gt 4) { $name = ($w[0..3] -join ' ') }
  $name = ($name -replace '(?i)\s*(및|와|과|그리고|,|and|or|of|the|for|with)$', '').Trim()   # cut after 4 words, "설치 및" must not stay
  if ($name.Length -gt 30) { return '' }
  $name = (Safe-Name $name 30).TrimStart('_').Trim()
  $key = ($name -replace '\s+', '').ToLowerInvariant()
  $hit = $names | Where-Object { ($_ -replace '\s+', '').ToLowerInvariant() -eq $key } | Select-Object -First 1
  if ($hit) { return $hit }
  return $name
}
function Get-WorktreeTopic([string]$logRoot, [string]$worktree, [string]$sid) {
  # Most common topic among this worktree's earlier session notes (other sessions only).
  if (-not (Test-Path -LiteralPath $logRoot)) { return '' }
  $count = @{}
  foreach ($n in @(Get-ChildItem -LiteralPath $logRoot -Recurse -File -Filter *.md)) {
    $seg = $n.FullName.Substring($logRoot.Length + 1).Split('\')
    if ($seg.Count -lt 2 -or $seg[0] -like '_*') { continue }
    $t = Read-Utf8 $n.FullName
    if ($t.Contains("<!-- session-capture:$sid -->")) { continue }
    $m = [regex]::Match((Get-Frontmatter $t), '(?m)^worktree:\s*"?([^"\r\n]+?)"?\s*$')
    if (-not $m.Success) { $m = [regex]::Match($t, ', [^,\r\n]+ / ([^,\r\n]+), \d{4}-\d{2}-\d{2} 작업 대화를') }   # older notes
    if ($m.Success -and $m.Groups[1].Value.Trim() -eq $worktree) { $count[$seg[0]] = 1 + [int]$count[$seg[0]] }
  }
  if ($count.Count -eq 0) { return '' }
  return ($count.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1).Key
}
function Get-SessionNotes {
  # Every captured session note: project log folders (+ the legacy 05_Sessions if it exists).
  $roots = @()
  if (Test-Path -LiteralPath $ProjRoot) { $roots += @(Get-ProjectFolders | ForEach-Object { Join-Path $_.FullName 'log' } | Where-Object { Test-Path -LiteralPath $_ }) }
  $legacy = Join-Path $VaultPath '05_Sessions'
  if (Test-Path -LiteralPath $legacy) { $roots += $legacy }
  foreach ($r in $roots) { Get-ChildItem -LiteralPath $r -Recurse -File -Filter *.md -ErrorAction SilentlyContinue }
}

# ---- Preflight ----
try { $null = Invoke-RestMethod -Uri $ApiBase -TimeoutSec 5 }
catch { Write-Log "ERROR: Ollama not reachable at $ApiBase. Abort."; exit 1 }

# ---- State (sessionId -> last captured mtime ticks) ----
$state = @{}
if (Test-Path -LiteralPath $StateFile) {
  try { (Get-Content -LiteralPath $StateFile -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $state[$_.Name] = [long]$_.Value } } catch { }
}

$cache = @{}
if (Test-Path -LiteralPath $CacheFile) {
  try {
    $cj = Get-Content -LiteralPath $CacheFile -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($sp in $cj.PSObject.Properties) {
      $hc = @{}
      foreach ($cp in $sp.Value.PSObject.Properties) { $hc[$cp.Name] = @{ done = @($cp.Value.done | Where-Object { $_ }); next = @($cp.Value.next | Where-Object { $_ }) } }
      $cache[$sp.Name] = $hc
    }
  } catch { $cache = @{} }
}

$cutoff = (Get-Date).AddHours(-$SinceHours)
$files = @(Get-ChildItem -LiteralPath $ProjectsBase -Recurse -Filter *.jsonl -ErrorAction SilentlyContinue |
  Where-Object { $_.Directory.Name -like $DirFilter -and $_.Directory.Name -ne 'subagents' -and $_.BaseName -notlike 'agent-*' -and $_.LastWriteTime -ge $cutoff } |
  Sort-Object CreationTimeUtc)   # a forked session comes after the one it was forked from
if ($files.Count -eq 0) { Write-Log 'No recent sessions. Nothing to capture.'; exit 0 }

# ---- Notes written before, by session marker (survives a manual move or rename) ----
$byMarker = @{}
foreach ($n in @(Get-SessionNotes)) {
  foreach ($mm in [regex]::Matches((Read-Utf8 $n.FullName), '<!-- session-capture:([0-9A-Za-z-]+) -->')) {
    $k = $mm.Groups[1].Value
    if (-not $byMarker.ContainsKey($k)) { $byMarker[$k] = @() }
    $byMarker[$k] = @($byMarker[$k]) + @($n.FullName)
  }
}

# Prompt fragments (and older placeholders): small models sometimes copy them verbatim.
# The prompt has no topical examples on purpose: an example about notifications leaked into
# three unrelated notes in testing, so the rules are stated without sample sentences.
$echo = @(
  '설정 변경', '알림 설정 변경', '알림 소리를 끄고 진동만 남겼다.',
  '실제로 한 일이나 결론을 담은 제목, 25자 이내', '이 작업의 결론 한 문장', '한 일과 정한 것, 2-5개의 짧은 문장', '정말 남은 일만 0-3개'
)
$captured = 0; $skipped = 0; $failed = 0
$touchedLogDirs = @{}

foreach ($f in $files) {
  try {
    $sid   = [System.IO.Path]::GetFileNameWithoutExtension($f.Name)
    $mtime = $f.LastWriteTimeUtc.Ticks
    if ($state.ContainsKey($sid) -and $state[$sid] -ge $mtime) { $skipped++; continue }
    $short  = $sid.Substring(0, [Math]::Min(8, $sid.Length))
    $marker = "<!-- session-capture:$sid -->"

    # ---- Extract conversation (user + assistant visible text) and the working directory ----
    # A forked or resumed session starts with copies of the earlier messages (marked forkedFrom):
    # those belong to the earlier session's note, so only what this session added is summarized.
    $lines = [System.IO.File]::ReadAllLines($f.FullName, [System.Text.Encoding]::UTF8)
    $turns = New-Object System.Collections.Generic.List[string]
    $cwd = ''; $ctx = ''; $parentSid = ''; $firstUser = $null; $inherited = 0; $lastAct = ''; $firstOwn = ''
    foreach ($l in $lines) {
      if ([string]::IsNullOrWhiteSpace($l)) { continue }
      if ($l -notmatch '"type"\s*:\s*"(user|assistant)"') { continue }
      try { $o = $l | ConvertFrom-Json } catch { continue }
      if ($o.type -ne 'user' -and $o.type -ne 'assistant') { continue }
      if (-not $cwd -and $o.cwd) { $cwd = [string]$o.cwd }
      if ($null -eq $o.message) { continue }
      $c = $o.message.content
      $txt = ''
      if ($c -is [string]) { $txt = $c }
      elseif ($c -is [System.Array]) { $txt = (($c | Where-Object { $_.type -eq 'text' } | ForEach-Object { $_.text }) -join "`n") }
      # What Claude actually ran: the one-line description of each command, and which files it edited.
      # Agentic sessions say little in visible text; without this a long edit session read as "status updates".
      $acts = @()
      if ($o.type -eq 'assistant' -and $c -is [System.Array]) {
        foreach ($b in @($c | Where-Object { $_.type -eq 'tool_use' })) {
          $d = [string]$b.input.description
          if (-not $d -and $b.name -match '^(Edit|Write|MultiEdit|NotebookEdit)$' -and $b.input.file_path) { $d = '파일 수정: ' + [System.IO.Path]::GetFileName([string]$b.input.file_path) }
          if ($d) { $acts += $d.Trim() }
        }
      }
      $txt = Clean-Turn $txt
      if ([string]::IsNullOrWhiteSpace($txt) -and $acts.Count -eq 0) { continue }
      $who = if ($o.message.role -eq 'assistant') { 'Claude' } else { '사용자' }
      if ($null -eq $firstUser -and $who -eq '사용자' -and $txt) { $firstUser = $txt }
      if ($o.forkedFrom) {
        $inherited++
        if (-not $parentSid -and $o.forkedFrom.sessionId) { $parentSid = [string]$o.forkedFrom.sessionId }
        if ($who -eq '사용자' -and $txt) { $ctx = $txt }
        continue
      }
      if ($txt) { $turns.Add("[$who] $txt"); if (-not $firstOwn -and $who -eq '사용자') { $firstOwn = $txt } }
      foreach ($a in $acts) { if ($a -ne $lastAct) { $turns.Add("[작업] $a"); $lastAct = $a } }
    }
    $loc = Get-OrcaLocation $cwd
    if ($null -eq $loc) { Write-Log "SKIP session $short (Orca 프로젝트 밖: $cwd)"; $skipped++; continue }
    $projDir = Get-ProjectDir $loc
    $logRoot = Join-Path $projDir 'log'

    # ---- Sessions with nothing of their own: leave no note (and remove an older one) ----
    $drop = ''
    if ($firstUser -and $firstUser.StartsWith('Generate a short git branch name')) { $drop = 'Orca가 브랜치 이름을 짓는 보조 대화' }
    elseif (-not ($turns | Where-Object { $_.StartsWith('[사용자]') })) { $drop = if ($inherited -gt 0) { '갈라진 뒤 새 대화 없음' } else { '사용자 발화 없음' } }
    if ($drop) {
      if ($byMarker.ContainsKey($sid)) {
        foreach ($p in @($byMarker[$sid])) { if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force; Write-Log ("     removed old note " + [System.IO.Path]::GetFileName($p)) } }
        [void]$byMarker.Remove($sid)
        $touchedLogDirs[$logRoot] = $true
      }
      $state[$sid] = $mtime
      Write-Log "SKIP session $short ($drop)"; $skipped++; continue
    }

    $intro = ''
    if ($inherited -gt 0) {
      $intro = "이 대화는 앞선 대화에서 갈라져 이어진 것이다. 앞부분은 따로 정리했으니, 새로 한 일만 정리한다."
      if ($ctx) { $intro += "`n갈라지기 직전 사용자의 말(맥락으로만 참고한다): " + $ctx.Substring(0, [Math]::Min(300, $ctx.Length)) }
      $intro += "`n"
    }

    $fullLen = 0; foreach ($t in $turns) { $fullLen += $t.Length + 2 }
    $partsInfo = ''; $many = $false
    $doneAll  = New-Object System.Collections.Generic.List[string]
    if ($fullLen -le $SingleMax) {
      # ---- Short session: one call over the whole conversation ----
      $convo = ($turns -join "`n`n")
      $prompt = "다음은 사용자와 Claude가 함께 작업한 대화 기록이다. $ActNote 나중에 이 작업을 다시 볼 사람이 한눈에 알아보도록 한국어로 정리하라.`n`n$Rules`n`n$FieldsOne`n$intro`n대화 기록:`n---`n$convo`n---"
    }
    else {
      # ---- Long session: a few lines per part (cached by content), then the note from those lines only ----
      # One 8B call over a compressed four-hour session invented work that never happened; small parts stay faithful.
      $many = $true
      $chunks = Get-Chunks $turns $ChunkChars
      $old = if ($cache.ContainsKey($sid)) { $cache[$sid] } else { @{} }
      $fresh = @{}; $newCount = 0
      $nextTail = New-Object System.Collections.Generic.List[string]
      for ($i = 0; $i -lt $chunks.Count; $i++) {
        $h = Get-Hash $chunks[$i]
        if ($old.ContainsKey($h)) { $r = $old[$h] }
        else {
          try {
            $mp = "다음은 긴 작업 대화의 한 부분이다 ($($i + 1)/$($chunks.Count)). $ActNote 이 부분에서 실제로 한 일과 정한 것을 한국어 평서문 1-3개로 쓴다 (done). 남은 일이 분명히 나오면 next에 `"~하기`"로 쓴다.`n`n$Rules`n`nJSON 객체 하나만 출력한다: {`"done`": [], `"next`": []}`n`n대화 부분:`n---`n$($chunks[$i])`n---"
            $mr = Invoke-Hermes $mp $MapSchema
            $r = @{ done = @(Clean-Lines $mr.done | ForEach-Object { Fix-Ending ($_ -replace '한다\.?$', '했다.') }); next = @(Clean-Lines $mr.next | ForEach-Object { To-Todo $_ }) }
            $newCount++
          } catch { Write-Log "WARN session $short part $($i + 1) failed: $($_.Exception.Message)"; continue }
        }
        $fresh[$h] = $r
        foreach ($d in @($r.done)) { if ($d) { $doneAll.Add([string]$d) } }
        if ($i -ge $chunks.Count - 3) { foreach ($x in @($r.next)) { if ($x) { $nextTail.Add([string]$x) } } }
      }
      $cache[$sid] = $fresh
      if ($doneAll.Count -eq 0) { Write-Log "SKIP session $short (부분 요약이 모두 비었다 - 다음에 다시)"; $skipped++; continue }
      $num = 0
      $list = (@($doneAll) | ForEach-Object { $num++; "$num. $_" }) -join "`n"
      $nl = if ($nextTail.Count -gt 0) { "`n`n남은 일 후보:`n" + ((@($nextTail) | ForEach-Object { '- ' + $_ }) -join "`n") } else { '' }
      $ask = if ($firstOwn) { "`n대화를 시작한 사용자의 요청(제목과 what을 정할 때 참고한다): " + $firstOwn.Substring(0, [Math]::Min(200, $firstOwn.Length)) + "`n" } else { '' }
      $prompt = "다음은 한 작업 대화에서 한 일을 순서대로 모은 목록이다. 이 목록만 보고 작업 기록을 정리한다. 목록에 없는 일은 쓰지 않는다.`n`n$Rules`n`n$FieldsMany`n$intro$ask`n한 일 목록:`n$list$nl"
      $partsInfo = ", 부분 $($chunks.Count)개 중 새로 $($newCount)개"   # "$newCount개" would read as one variable name
    }
    $data = Invoke-Hermes $prompt $(if ($many) { $ManySchema } else { $SummarySchema })
    $tokens = $script:LastPromptTokens
    if ($tokens -ge ($NumCtx - 800)) { Write-Log "WARN session $short input $tokens tokens is near num_ctx $NumCtx" }
    if ($DebugDir) {
      try {
        if (-not (Test-Path -LiteralPath $DebugDir)) { New-Item -ItemType Directory -Force -Path $DebugDir | Out-Null }
        Write-Utf8 (Join-Path $DebugDir "$short.json") (([ordered]@{ session = $sid; chars = $fullLen; prompt = $prompt; answer = $data }) | ConvertTo-Json -Depth 6)
      } catch { }
    }

    $keep = { param($arr) @(Clean-Lines $arr) }
    $one  = { param($v) $v = @(Clean-Lines @($v)) | Select-Object -First 1; if ($v) { Fix-Ending ([string]$v) } else { '' } }
    $what     = [string](& $one $data.what)
    $result   = [string](& $one $data.result)
    if ($many) {
      # Steps are the part summaries the model picked by number, kept in session order.
      $picked = @(@($data.how) | ForEach-Object { try { [int]$_ } catch { 0 } } | Where-Object { $_ -ge 1 -and $_ -le $doneAll.Count } | Select-Object -Unique | Sort-Object)
      # Cover the whole session: one step from each of up to five stretches. The model's pick
      # wins inside a stretch; otherwise a decision line, else the most specific (longest) line.
      # Left alone, the model took four trivial picks from the first hour of a four-hour session.
      $total = $doneAll.Count; $segN = [Math]::Min(5, $total)
      $final = New-Object System.Collections.Generic.List[int]
      for ($sg = 0; $sg -lt $segN; $sg++) {
        $lo = [int][Math]::Floor($sg * $total / $segN) + 1
        $hi = [int][Math]::Floor(($sg + 1) * $total / $segN)
        $inSeg = @($picked | Where-Object { $_ -ge $lo -and $_ -le $hi })
        if ($inSeg.Count -gt 0) { $final.Add([int]$inSeg[0]); continue }
        # Specific but readable: longer is better up to 120 characters, longer than that counts against it.
        $best = @($lo..$hi) | Sort-Object @{ Expression = { if ($doneAll[$_ - 1] -match '하기로|정했|결정') { 1 } else { 0 } }; Descending = $true },
                                         @{ Expression = { $len = $doneAll[$_ - 1].Length; if ($len -le 120) { $len } else { 240 - $len } }; Descending = $true } | Select-Object -First 1
        if ($best) { $final.Add([int]$best) }
      }
      $how = @(Clean-Lines @($final | Sort-Object -Unique | ForEach-Object { $doneAll[$_ - 1] }))   # cached lines may predate a newer filter
    }
    else {
      $how = @(& $keep $data.how | ForEach-Object { Fix-Ending ($_ -replace '한다\.?$', '했다.') })   # steps are done: past tense
    }
    $what     = $what -replace '할 것이다\.?$', '하기로 했다.'
    $nextList = @(& $keep $data.next | ForEach-Object { To-Todo $_ } | Where-Object { $_ -ne '' })
    $rawTitle = if (Is-Echo ([string]$data.title)) { '' } else { Fix-Title $data.title }
    if (Is-Echo $rawTitle) { $rawTitle = '' }

    # Drop filler: a copied request or question, process talk, commands, code, cut-off lines, hedged todos.
    $what = $what -replace '^사용자(가|는|의 요청(으로|에 따라))\s*,?\s*', ''
    if ($what -match '(해라|해줘|해 줘|하라|해주세요)\.?$' -or $what -match '\?\s*$' -or $what -match $codeRx) { $what = '' }
    if ($result -match $codeRx) { $result = '' }
    if ($rawTitle -match $codeRx) { $rawTitle = '' }
    $how      = @($how | Where-Object { $_ -notmatch $fluff -and $_ -notmatch $cmdRx -and $_ -notmatch $codeRx -and $_ -notmatch $cutRx } | Select-Object -First 5)
    # A todo ends in "~하기"; a line still ending in "~다" is a statement ("플러그인이 로드된다"), not a todo.
    $nextList = @($nextList | Where-Object { $_ -notmatch $hedge -and $_ -notmatch $buzz -and $_ -notmatch '^사용자' -and $_ -notmatch $codeRx -and $_ -notmatch $cutRx -and $_ -notmatch '다$' -and $_.Length -ge 8 -and $_ -match '^[\p{L}\p{N}/]' } | Select-Object -Unique | Select-Object -First 3)

    # Say each thing once: the result line is not repeated as "what" or as a step.
    $key = { param($s) (([string]$s) -replace '[\s\.,]', '') }
    if ($what -ne '' -and ((& $key $what) -eq (& $key $result) -or (Get-Dice $what $result) -ge 0.5)) { $what = '' }
    $how = @($how | Where-Object { $k = & $key $_; $k -ne (& $key $result) -and $k -ne (& $key $what) })
    if ($result -eq '' -and $what -ne '') { $result = $what; $what = '' }
    if ($result -eq '' -and $how.Count -gt 0) { $result = $how[-1]; $how = @($how | Select-Object -SkipLast 1) }
    # The callout is one line: a long multi-sentence result keeps its first sentence.
    if ($result.Length -gt 120) { $first = ($result -split '(?<=다\.)\s+')[0]; if ($first.Length -ge 15) { $result = $first } }
    # A result made of stock praise ("효율이 높아졌다") says nothing: use the last concrete step.
    if ($result -match $buzzR) {
      $alt = @($how | Where-Object { $_ -notmatch $buzzR }) | Select-Object -Last 1
      if ($alt) { $result = $alt; $how = @($how | Where-Object { $_ -ne $alt }) }
    }
    # ---- Guard: never write an empty note (would be pure noise) ----
    if ($result -eq '') { Write-Log "SKIP session $short (빈 요약 - 기록 안 함)"; $skipped++; continue }

    # A title built from stock phrases says nothing; prefer a concrete sentence from the summary.
    if ($rawTitle -eq '' -or $rawTitle -match $buzz) {
      $alt = @(@($what) + @($result) + @($how) | Where-Object { $_ -and $_ -notmatch $buzz -and $_.Length -le 40 }) | Select-Object -First 1
      if ($alt) { $rawTitle = Fix-Title $alt }
    }
    # A long, sentence-like or non-Korean title: ask once for a short Korean name built from the summary.
    $noHangul = ($rawTitle -notmatch '[가-힣]' -and $result -match '[가-힣]')
    if ($rawTitle.Length -gt 28 -or $rawTitle -match '다$' -or $noHangul) {
      try {
        $p4 = "다음 작업에 한국어로 짧은 이름을 지어라. 20자 안팎으로, 문장이 아니라 `"~하기`"나 명사로 끝나는 이름으로 쓴다. `"완료`", `"진행`"은 붙이지 않는다. 고유명사는 영어 표기를 쓴다.`n`n하려던 일: $what`n결과: $result`n한 일: " + (@($how) -join ' / ')
        $t2 = Fix-Title ([string](Invoke-Hermes $p4 $TitleSchema).title)
        $better = ($t2.Length -lt $rawTitle.Length -or $noHangul -or $rawTitle -match '다$')
        if ($t2 -ne '' -and $t2.Length -le 30 -and $better -and -not (Is-Echo $t2) -and $t2 -notmatch $buzz -and $t2 -notmatch $codeRx) { $rawTitle = $t2 }
      } catch { }
    }
    $title = if ($rawTitle -ne '') { $rawTitle } else { '제목 없음' }

    # ---- Where the note lives: reuse the folder and name chosen the first time ----
    $mine = @()
    if ($byMarker.ContainsKey($sid)) { $mine = @($byMarker[$sid] | Where-Object { Test-Path -LiteralPath $_ }) }
    $prev = @($mine | Where-Object { $_.StartsWith($logRoot + '\', [System.StringComparison]::OrdinalIgnoreCase) }) | Select-Object -First 1
    $topic = ''; $dir = ''; $keepName = $false
    if ($prev) {
      $seg = $prev.Substring($logRoot.Length + 1).Split('\')
      if ($seg.Count -ge 2 -and $seg[0] -notlike '_*') { $topic = $seg[0]; $dir = Split-Path -Parent $prev }
      $keepName = ([System.IO.Path]::GetFileName($prev) -notmatch '^\d{4}-\d{2}-\d{2} ')   # older "<date> <title>" names are renamed once
    }
    if ($topic -eq '') {
      # Topic inside the project: schema-constrained call over that project's topics.
      $items = @(@($what) + @($how) + @($result) | Where-Object { $_ })
      $topic = Get-Topic (Get-TopicRegistry $projDir) $title $items $loc.Worktree
      if ($topic -ne '' -and @((Get-TopicRegistry $projDir).Keys) -notcontains $topic) {
        $wtTopic = Get-WorktreeTopic $logRoot $loc.Worktree $sid
        if ($wtTopic) { Write-Log ("     new topic '$topic' folded into worktree topic '$wtTopic'"); $topic = $wtTopic }
      }
      if ($topic -eq '') { $topic = $Unfiled }
      $dir = Join-Path $logRoot $topic
    }
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $touchedLogDirs[$logRoot] = $true

    $base = if ($keepName) { [System.IO.Path]::GetFileNameWithoutExtension($prev) } else { Safe-Name $title 40 }
    if ($base -eq '') { $base = $short }
    $newFull = Join-Path $dir "$base.md"
    $taken = { param($p) ($p -ne $prev) -and (Test-Path -LiteralPath $p) -and -not (Read-Utf8 $p).Contains($marker) }
    if (& $taken $newFull) {
      # Another session already uses this title: ask once for a name that shows the difference.
      try {
        $other = ([regex]::Match((Read-Utf8 $newFull), '(?m)^> \[!summary\]\s*(.+)$')).Groups[1].Value.Trim()
        $p3 = "다음 두 작업 기록이 같은 제목 `"$base`"을 쓰고 있다. 두 번째 기록에 새 제목을 지어라. 첫 번째와 무엇이 다른지 드러나는 20자 안팎의 짧은 이름으로 쓴다. 문장으로 쓰지 않고 `"완료`", `"진행`"을 붙이지 않는다.`n`n첫 번째 기록: $other`n두 번째 기록: $result " + (@($how) -join ' ')
        $alt = Safe-Name (Fix-Title ([string](Invoke-Hermes $p3 $TitleSchema).title)) 40
        if ($alt -ne '' -and -not (Is-Echo $alt)) { $base = $alt; $newFull = Join-Path $dir "$base.md" }
      } catch { }
      $n = 2
      while (& $taken $newFull) { $newFull = Join-Path $dir "$base $n.md"; $n++ }
    }

    # ---- Body: result first, then what and how, then what is left; the source folded below ----
    $topicLine = if ($topic -eq $Unfiled) { '주제: 아직 정하지 못했다' } else { "주제: [[$topic]]" }
    $parts = New-Object System.Collections.Generic.List[string]
    $parts.Add("> [!summary] $result")
    if ($what -ne '') { $parts.Add("**무엇을** $what") }
    if ($how.Count -gt 0) { $parts.Add("**어떻게**`n" + ((@($how) | ForEach-Object { '- ' + $_ }) -join "`n")) }
    if ($nextList.Count -gt 0) { $parts.Add("**다음에 할 일**`n" + ((@($nextList) | ForEach-Object { '- [ ] ' + $_ }) -join "`n")) }
    $parentLine = ''
    if ($parentSid -and $parentSid -ne $sid -and $byMarker.ContainsKey($parentSid)) {
      $pp = @($byMarker[$parentSid] | Where-Object { Test-Path -LiteralPath $_ }) | Select-Object -First 1
      if ($pp) { $parentLine = "`n> 이어진 대화: [[" + [System.IO.Path]::GetFileNameWithoutExtension($pp) + "]]" }
    }
    $parts.Add("> [!info]- 출처`n> $topicLine$parentLine`n> $($loc.Project) 프로젝트의 $($loc.Worktree) 폴더에서 나눈 대화를 자동으로 요약했다.")
    $actDate = $f.LastWriteTime.ToString('yyyy-MM-dd')   # day of last activity
    $front = "---`ntags: [`"작업기록`"]`ntopic: `"$topic`"`nproject: `"$($loc.Project)`"`nworktree: `"$($loc.Worktree)`"`nupdated: $actDate`nsource: hermes`n---"
    $note = $front + "`n`n" + ($parts -join "`n`n") + "`n" + $marker

    # Text a person wrote below the marker survives the rewrite.
    $tail = ''
    if ($prev) {
      $old = Read-Utf8 $prev
      $i = $old.IndexOf($marker)
      if ($i -ge 0) { $rest = $old.Substring($i + $marker.Length); if ($rest.Trim() -ne '') { $tail = $rest.TrimEnd() } }
    }
    Write-Utf8 $newFull ((Clean-Text $note) + $tail + "`n")
    foreach ($p in $mine) { if ($p -ne $newFull -and (Test-Path -LiteralPath $p)) { Remove-Item -LiteralPath $p -Force } }
    $byMarker[$sid] = @($newFull)
    $state[$sid] = $mtime
    Write-Log ("OK   session $short -> " + (Split-Path $projDir -Leaf) + "/log/$topic/" + [System.IO.Path]::GetFileName($newFull) + "  (입력 $tokens 토큰$partsInfo)")
    $captured++
  }
  catch {
    Write-Log ("FAIL $($f.Name)  $($_.Exception.Message)")
    $failed++
  }
}

# ---- Remove topic folders left empty after a session moved to another topic ----
foreach ($lr in $touchedLogDirs.Keys) {
  Get-ChildItem -LiteralPath $lr -Directory -ErrorAction SilentlyContinue |
    Where-Object { -not (Get-ChildItem -LiteralPath $_.FullName -Force | Select-Object -First 1) } |
    ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force }
}

try { ($state | ConvertTo-Json) | Set-Content -LiteralPath $StateFile -Encoding UTF8 } catch { Write-Log "WARN: could not write state file" }
# Keep part summaries only for sessions still in the window (an older session is not captured again).
$live = @{}; foreach ($f in $files) { $live[[System.IO.Path]::GetFileNameWithoutExtension($f.Name)] = $true }
foreach ($k in @($cache.Keys)) { if (-not $live.ContainsKey($k)) { $cache.Remove($k) } }
try { ($cache | ConvertTo-Json -Depth 6) | Set-Content -LiteralPath $CacheFile -Encoding UTF8 } catch { Write-Log "WARN: could not write cache file" }
Write-Log ("Done. captured=$captured skipped=$skipped failed=$failed")
