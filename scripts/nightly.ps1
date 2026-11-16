<#
.SYNOPSIS
  Nightly pipeline of the 7th brain. Runs at 03:00 via Task Scheduler.
.DESCRIPTION
  Step 0: orca-map.ps1 - save Orca's project list (folders anywhere, worktrees, groups).
  Step 1: capture-sessions.ps1 (Hermes, local)    - summarize recent Claude Code sessions in Orca projects.
          codex-to-claude.ps1 + capture-sessions.ps1 again for Codex sessions run inside Orca.
  Step 2: process-inbox.ps1    (Hermes, local)    - summary, tags, related notes for new Inbox notes.
  Step 3: gardener.ps1         (Claude or Codex)  - daily note, topic notes, project first pages, work preferences,
                                                    the #정리해줘 queue, weekly note on Mondays.
  Each step runs in its own child process so one failing does not stop the others.
#>
$dir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ps = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File')
& powershell.exe @ps (Join-Path $dir 'orca-map.ps1')
& powershell.exe @ps (Join-Path $dir 'capture-sessions.ps1')
& powershell.exe @ps (Join-Path $dir 'codex-to-claude.ps1')
$codexOut = Join-Path $dir 'codex-transcripts'
if (Test-Path -LiteralPath $codexOut) { & powershell.exe @ps (Join-Path $dir 'capture-sessions.ps1') -ProjectsBase $codexOut }
& powershell.exe @ps (Join-Path $dir 'collect-references.ps1')
& powershell.exe @ps (Join-Path $dir 'process-inbox.ps1')
& powershell.exe @ps (Join-Path $dir 'gardener.ps1')
& powershell.exe @ps (Join-Path $dir 'apply-topic-plan.ps1')
& powershell.exe @ps (Join-Path $dir 'sync-prefs.ps1')
