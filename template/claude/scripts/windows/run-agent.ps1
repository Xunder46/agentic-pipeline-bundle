<#
Runs a GitHub Copilot CLI agent in the background, waits for it, and prints a compact summary
(status, changed files, health, log tail) for the governing Claude Code session. Windows edition of
.claude/scripts/macos/run-agent.sh — same commands, same summary format.

  pwsh -NoProfile -File .claude/scripts/windows/run-agent.ps1 start  <agent> <prompt-file> [model]
  pwsh -NoProfile -File .claude/scripts/windows/run-agent.ps1 wait   <RUN_ID>
  pwsh -NoProfile -File .claude/scripts/windows/run-agent.ps1 status <RUN_ID>
  pwsh -NoProfile -File .claude/scripts/windows/run-agent.ps1 stop   <RUN_ID>
  pwsh -NoProfile -File .claude/scripts/windows/run-agent.ps1 list

Each run gets .work/runs/<RUN_ID>/ (output.log, exit code, git snapshot, proxy.log). Settings come from
.claude/pipeline.env; an environment variable of the same name overrides the file.

Agents are the Copilot editions in .github/agents/<agent>.agent.md. Tool permissions come ONLY from
.github/copilot/permissions/common.flags + <agent>.flags: the runner never passes --allow-all-tools,
refuses to start an agent that has no profile, and refuses any profile that grants everything.
Works in Windows PowerShell 5.1 and PowerShell 7.
#>
param(
  [Parameter(Position = 0)][string]$Command,
  [Parameter(Position = 1)][string]$Arg1,
  [Parameter(Position = 2)][string]$Arg2,
  [Parameter(Position = 3)][string]$Arg3
)
$ErrorActionPreference = 'Stop'

$ScriptPath = $MyInvocation.MyCommand.Path
$ScriptDir = Split-Path -Parent $ScriptPath
$OrigPwd = (Get-Location).Path
$RepoRoot = (& git rev-parse --show-toplevel).Trim()
Set-Location $RepoRoot
$Runs = Join-Path $RepoRoot '.work/runs'
New-Item -ItemType Directory -Force -Path $Runs | Out-Null
$AgentsDir = Join-Path $RepoRoot '.github/agents'
$PermissionsDir = Join-Path $RepoRoot '.github/copilot/permissions'

# ---- Settings ------------------------------------------------------------------------------------
$FileSettings = @{}
$envFile = Join-Path $RepoRoot '.claude/pipeline.env'
if (Test-Path $envFile) {
  foreach ($line in Get-Content $envFile) {
    if ($line -match '^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.*?)\s*$') {
      $v = $Matches[2]
      if ($v -match '^"(.*)"$' -or $v -match "^'(.*)'$") { $v = $Matches[1] }
      $FileSettings[$Matches[1]] = $v
    }
  }
}
function Get-Setting([string]$name, [string]$default) {
  $e = [Environment]::GetEnvironmentVariable($name)
  if ($null -ne $e) { return $e }
  if ($FileSettings.ContainsKey($name)) { return $FileSettings[$name] }
  return $default
}
$WaitMinutes = [int](Get-Setting 'WAIT_MINUTES' '15')
$TailLines = [int](Get-Setting 'TAIL_LINES' '40')
$PollSeconds = [int](Get-Setting 'POLL_SECONDS' '15')
$CopilotBin = Get-Setting 'COPILOT_BIN' 'copilot'
$CopilotWrapper = Get-Setting 'COPILOT_WRAPPER' ''
$MaxRunMinutes = [int](Get-Setting 'MAX_RUN_MINUTES' '120')
$StallMinutes = [int](Get-Setting 'STALL_MINUTES' '30')
$RepeatStop = [int](Get-Setting 'REPEAT_STOP' '40')
$NoWriteStop = [int](Get-Setting 'NO_WRITE_STOP' '20')   # stop an implementer that has changed no file after this long; 0 = off
$LongRunMinutes = [int](Get-Setting 'LONG_RUN_MINUTES' '30')   # warn when an implementer run passes this long; 0 = off
$NoCustomInstructions = (Get-Setting 'COPILOT_NO_CUSTOM_INSTRUCTIONS' '1') -eq '1'   # agents do not auto-load AGENTS.md / CLAUDE.md
$HungChildMinutes = [int](Get-Setting 'HUNG_CHILD_MINUTES' '10')
# The macOS wrapper name maps to its Windows counterpart.
if ($CopilotWrapper -eq 'with-opencode.sh') { $CopilotWrapper = 'with-opencode.ps1' }

function Show-Usage { Get-Content $ScriptPath | Select-Object -Skip 5 -First 5 | ForEach-Object { [Console]::Error.WriteLine($_.Trim()) }; exit 2 }
function Get-Now { [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() }
function Get-MinutesSince([long]$epoch) { '{0:N1}' -f (((Get-Now) - $epoch) / 60.0) }
function Write-Text([string]$path, [string]$text) { [IO.File]::WriteAllText($path, $text) }
function Read-Text([string]$path) { if (Test-Path $path) { [IO.File]::ReadAllText($path).Trim() } else { '' } }

# ---- Permissions ---------------------------------------------------------------------------------
$Interpreters = 'bash|sh|zsh|fish|pwsh|powershell|cmd|python[0-9.]*|py|node|perl|ruby|env|xargs|eval|exec|iex|invoke-expression|start-process'
function Get-Permissions([string]$agent) {
  $flags = New-Object System.Collections.Generic.List[string]
  foreach ($file in @((Join-Path $PermissionsDir 'common.flags'), (Join-Path $PermissionsDir "$agent.flags"))) {
    $rel = $file.Substring($RepoRoot.Length + 1)
    if (-not (Test-Path $file)) {
      [Console]::Error.WriteLine("No permission profile: $rel - refusing to run '$agent' (install the github/ part of the pipeline, or write the profile).")
      exit 2
    }
    foreach ($raw in Get-Content $file) {
      $line = $raw.Trim()
      if ($line -eq '' -or $line.StartsWith('#')) { continue }
      if ($line -match '^--(allow-all-tools|allow-all|yolo|allow-all-paths|allow-all-urls)(=|$)') {
        [Console]::Error.WriteLine("Refusing to run: $rel grants everything ($line). Grant tools one by one."); exit 2
      }
      if ($line -notmatch '^--deny-tool=' -and $line -match "shell\((\.?[\\/])?($Interpreters)([\s:)]|\.exe)") {
        [Console]::Error.WriteLine("Refusing to run: $rel allows an interpreter ($line), which can run anything. Route the command through the gateway instead."); exit 2
      }
      if (-not $line.StartsWith('--')) {
        [Console]::Error.WriteLine("Refusing to run: $rel has a line that is not a flag: $line"); exit 2
      }
      $flags.Add($line)
    }
  }
  return , $flags.ToArray()
}

# Implementers write code; planners and the reviewer legitimately change few or no files.
function Test-Implementer([string]$agent) { $agent -notin 'conductor', 'conductor-v2', 'code-reviewer' }

# The standing rules for one agent: the sections of .github/copilot/agent-rules.md headed
# "## Every agent" or naming the agent in parentheses. Appended to every prompt, so briefs never carry
# (possibly stale) copies of them.
function Get-AgentRules([string]$agent) {
  $file = Join-Path $RepoRoot '.github/copilot/agent-rules.md'
  if (-not (Test-Path $file)) { return '' }
  $out = @(); $inc = $false; $comment = $false
  foreach ($l in (Get-Content -Path $file -Encoding UTF8)) {
    if ($l.StartsWith('<!--')) { $comment = $true }
    if ($comment) { if ($l -match '-->') { $comment = $false }; continue }
    if ($l.StartsWith('## ')) {
      $inc = $l.StartsWith('## Every agent')
      if ($l -match '\(([^)]*)\)') { if (($Matches[1] -split '[ ,]+') -contains $agent) { $inc = $true } }
    }
    if ($inc) { $out += $l }
  }
  return ($out -join "`n")
}

# The "Known long-running or hanging commands" section of AGENTS.md, without its HTML comment.
# Injected into the prompt because agents run with --no-custom-instructions.
function Get-KnownHangs {
  $file = Join-Path $RepoRoot 'AGENTS.md'
  if (-not (Test-Path $file)) { return '' }
  $out = @(); $on = $false; $comment = $false
  foreach ($l in (Get-Content -Path $file -Encoding UTF8)) {
    if ($l.StartsWith('## Known long-running or hanging commands')) { $on = $true; continue }
    if (-not $on) { continue }
    if ($l.StartsWith('## ')) { break }
    if ($l -match '<!--') { $comment = $true }
    if ($comment) { if ($l -match '-->') { $comment = $false }; continue }
    if ($l.Trim()) { $out += $l }
  }
  return ($out -join "`n")
}

function Get-RoleModel([string]$agent) {
  switch ($agent) {
    { $_ -in 'conductor', 'conductor-v2' } { return (Get-Setting 'PLANNER_MODEL' '') }
    'code-reviewer' { return (Get-Setting 'REVIEWER_MODEL' '') }
    default { return (Get-Setting 'DEVELOPER_MODEL' '') }
  }
}

# ---- Git helpers ---------------------------------------------------------------------------------
function Get-StatusLines { @(& git -c core.quotepath=off status --porcelain=v1 -uall) }
function Get-DiffFingerprint {
  $text = ((& git -c core.quotepath=off diff --numstat) + (& git -c core.quotepath=off ls-files --others --exclude-standard) |
      Where-Object { $_ -notmatch '(^|\s)\.work/' }) -join "`n"
  $sha = [Security.Cryptography.SHA1]::Create()
  ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)))).Replace('-', '')
}

function Get-RunDir([string]$id) {
  $dir = Join-Path $Runs $id
  if (-not (Test-Path $dir)) { [Console]::Error.WriteLine("Unknown run id: $id"); exit 2 }
  return $dir
}
function Test-WorkerAlive([string]$dir) {
  $pidText = Read-Text (Join-Path $dir 'pid')
  if (-not $pidText) { return $false }
  return [bool](Get-Process -Id ([int]$pidText) -ErrorAction SilentlyContinue)
}
function Get-Descendants([int]$parent) {
  $all = @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name, CreationDate, KernelModeTime, UserModeTime, CommandLine)
  $result = @(); $queue = @($parent)
  while ($queue.Count -gt 0) {
    $p = $queue[0]; $queue = @($queue | Select-Object -Skip 1)
    foreach ($c in ($all | Where-Object { $_.ParentProcessId -eq $p })) { $result += $c; $queue += [int]$c.ProcessId }
  }
  return $result
}

# ---- Worker --------------------------------------------------------------------------------------
function Invoke-Worker([string]$dir) {
  $agent = Read-Text (Join-Path $dir 'agent')
  $promptFile = Read-Text (Join-Path $dir 'prompt_file')
  $model = Read-Text (Join-Path $dir 'model')
  $prompt = "Your task brief is in the file $promptFile. Read the whole file and carry it out. You cannot ask the user questions in this run. If something is unclear, make the most reasonable choice and list each such choice under an Open questions heading at the end of your final response."
  $rules = Get-AgentRules $agent
  if ($rules) { $prompt += "`n`nStanding rules for every run (a brief may add to them, never relax them):`n`n" + $rules }
  $flags = Get-Permissions $agent
  $hangs = Get-KnownHangs
  if ($hangs) { $prompt += "`n`nKnown long-running or hanging commands in this repository:`n`n" + $hangs }
  $copilotArgs = @('-p', $prompt, '--agent', $agent, '--no-ask-user') + $flags
  if ($NoCustomInstructions) { $copilotArgs += '--no-custom-instructions' }
  if ($model) { $copilotArgs += @('--model', $model) }
  $env:OPENCODE_SESSION = 'copilot-' + (Split-Path -Leaf $dir)
  $env:OPENCODE_PROXY_LOG = Join-Path $dir 'proxy.log'
  $log = Join-Path $dir 'output.log'
  $code = 1
  try {
    if ($CopilotWrapper) {
      & (Join-Path $ScriptDir $CopilotWrapper) $CopilotBin @copilotArgs *> $log
    } else {
      & $CopilotBin @copilotArgs *> $log
    }
    $code = $LASTEXITCODE
  } catch {
    Add-Content -Path $log -Value "run-agent: $($_.Exception.Message)"
    $code = 1
  }
  if (-not (Test-Path (Join-Path $dir 'exit'))) { Write-Text (Join-Path $dir 'exit') "$code" }
}

function Start-Run([string]$agent, [string]$promptFile, [string]$model) {
  $abs = $promptFile
  if (-not [IO.Path]::IsPathRooted($abs)) { $abs = Join-Path $OrigPwd $promptFile }
  if (-not (Test-Path $abs)) { [Console]::Error.WriteLine("Prompt file not found: $promptFile"); exit 2 }
  $abs = (Resolve-Path $abs).Path
  $rel = $abs
  $rootNorm = $RepoRoot.Replace('/', '\').TrimEnd('\') + '\'
  if ($abs.Replace('/', '\').StartsWith($rootNorm, [StringComparison]::OrdinalIgnoreCase)) {
    $rel = $abs.Replace('/', '\').Substring($rootNorm.Length).Replace('\', '/')
  }
  if (-not (Test-Path (Join-Path $AgentsDir "$agent.agent.md"))) {
    [Console]::Error.WriteLine("No Copilot agent .github/agents/$agent.agent.md - refusing to run (the .claude/ edition has no Copilot permissions).")
    exit 2
  }
  $null = Get-Permissions $agent   # validate now, so a bad profile fails before anything starts
  if (-not $model) { $model = Get-RoleModel $agent }

  $id = (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + ($agent -replace '[^A-Za-z0-9_-]', '')
  $dir = Join-Path $Runs $id
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  Write-Text (Join-Path $dir 'agent') $agent
  Write-Text (Join-Path $dir 'prompt_file') $rel
  Write-Text (Join-Path $dir 'model') "$model"
  Write-Text (Join-Path $dir 'wrapper') $(if ($CopilotWrapper) { $CopilotWrapper } else { 'none' })
  Set-Content -Path (Join-Path $dir 'before') -Value (Get-StatusLines)
  Write-Text (Join-Path $dir 'started_epoch') "$(Get-Now)"
  Write-Text (Join-Path $dir 'diff_fp') (Get-DiffFingerprint)
  Write-Text (Join-Path $dir 'diff_changed_epoch') "$(Get-Now)"
  Write-Text (Join-Path $dir 'started') ''
  Write-Text (Join-Path $Runs 'latest.txt') $id

  $self = (Get-Process -Id $PID).Path
  $argLine = '-NoProfile -ExecutionPolicy Bypass -File "' + $ScriptPath + '" __worker "' + $dir + '"'
  $p = Start-Process -FilePath $self -ArgumentList $argLine -WindowStyle Hidden -PassThru
  Write-Text (Join-Path $dir 'pid') "$($p.Id)"
  return $id
}

# ---- Health --------------------------------------------------------------------------------------
# Loop signals from the agent log (same rules as the macOS runner's log_stats):
#   Action/ActionKey  the most repeated tool call. Copilot logs each call as "● <title>" ("✗ <title>"
#                     when it failed or was denied) followed by "  │ <command or path>". The model
#                     rewrites titles freely, so a shell call is keyed on its command and a read on its
#                     path and line range; edits keep their title (many edits to one plan are normal).
#   Denied            calls refused by the permission profile (each retry counts).
#   Text              the most repeated prose line: a degenerating model writes the same filler line
#                     thousands of times with no tool calls.
function Get-LogStats([string]$log) {
  $r = @{ Action = 0; ActionKey = '-'; Denied = 0; Text = 0; Read = 0; ReadKey = '-' }
  if (-not (Test-Path $log)) { return $r }
  $dot = [string][char]0x25CF + ' '; $cross = [string][char]0x2717 + ' '
  $bar = '  ' + [char]0x2502 + ' '; $corner = '  ' + [char]0x2514 + ' '
  $act = @{}; $text = @{}; $reads = @{}; $key = ''; $kind = ''; $stage = 0
  foreach ($l in (Get-Content -Path $log -Encoding UTF8)) {
    if ($l.StartsWith($dot) -or $l.StartsWith($cross) -or $l.StartsWith('/ ')) {
      if ($key) { $act[$key] = 1 + [int]$act[$key] }
      $t = (($l.Substring(2) -replace '\s+[0-9.]+m?s\s*$', '') -replace '\s+', ' ').Trim().ToLowerInvariant() -replace '[0-9]+', '#'
      $kind = if ($t -match '\(shell\)$') { 'shell' } else { ($t -split ' ')[0] }
      $key = $t; $stage = if ($kind -in 'edit', 'create') { 0 } else { 1 }
      continue
    }
    if ($stage -eq 1 -and $l.StartsWith($bar)) {
      $c = ($l.Substring(4) -replace '\s+', ' ').Trim(); $key = $kind + ': ' + $c
      if ($kind -eq 'read') { $reads[$c] = 1 + [int]$reads[$c] }
      $stage = 2; continue
    }
    if ($stage -eq 2 -and $l.StartsWith($corner) -and $l.Substring(4) -match '^(L[0-9]+:[0-9]+)') { $key = $key + ' ' + $Matches[1]; $stage = 0; continue }
    if ($l -match 'Permission denied and could not request permission|Permission to run this tool was denied') { $r.Denied++ }
    if ($l -match '^\s*$' -or $l.StartsWith($bar) -or $l.StartsWith($corner)) { continue }
    $stage = 0
    $x = ($l -replace '\s+', ' ').Trim().ToLowerInvariant()
    if ($x.Length -ge 8) { $text[$x] = 1 + [int]$text[$x] }
  }
  if ($key) { $act[$key] = 1 + [int]$act[$key] }
  if ($act.Count -gt 0) {
    $top = $act.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1
    $r.Action = [int]$top.Value; $r.ActionKey = [string]$top.Key
    if ($r.ActionKey.Length -gt 100) { $r.ActionKey = $r.ActionKey.Substring(0, 100) }
  }
  if ($text.Count -gt 0) { $r.Text = [int]($text.Values | Measure-Object -Maximum).Maximum }
  if ($reads.Count -gt 0) {
    $top = $reads.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1
    $r.Read = [int]$top.Value; $r.ReadKey = [string]$top.Key
  }
  return $r
}
# Prose repeats this often count as degeneration (well above any real report's repeated lines).
function Get-FillerLimit { [Math]::Max(200, $RepeatStop * 5) }

function Get-HungChildren([string]$dir) {
  if (-not (Test-WorkerAlive $dir)) { return @() }
  $out = @()
  foreach ($c in (Get-Descendants ([int](Read-Text (Join-Path $dir 'pid'))))) {
    if ($c.Name -match '^(copilot|node|pwsh|powershell|cmd|conhost|taskkill)(\.exe)?$') { continue }
    if (-not $c.CreationDate) { continue }
    $ageMin = ((Get-Date) - $c.CreationDate).TotalMinutes
    $cpuSec = ([double]$c.KernelModeTime + [double]$c.UserModeTime) / 1e7
    if ($ageMin -ge $HungChildMinutes -and $cpuSec -lt ($ageMin * 60 * 0.01)) {
      $cmd = [string]$c.CommandLine; if ($cmd.Length -gt 120) { $cmd = $cmd.Substring(0, 120) }
      $out += ('{0} {1}m {2}' -f $c.ProcessId, [int]$ageMin, $cmd)
    }
  }
  return $out
}

# True while the run has changed no file in the working tree (its diff fingerprint never moved).
function Test-NoWriteYet([string]$dir) { (Read-Text (Join-Path $dir 'diff_changed_epoch')) -eq (Read-Text (Join-Path $dir 'started_epoch')) }

function Update-Health([string]$dir) {
  $fp = Get-DiffFingerprint
  if ($fp -ne (Read-Text (Join-Path $dir 'diff_fp'))) {
    Write-Text (Join-Path $dir 'diff_fp') $fp
    Write-Text (Join-Path $dir 'diff_changed_epoch') "$(Get-Now)"
  }
  if (Test-Path (Join-Path $dir 'exit')) { return }
  if (-not (Test-WorkerAlive $dir)) { return }
  $id = Split-Path -Leaf $dir
  $elapsedMin = ((Get-Now) - [long](Read-Text (Join-Path $dir 'started_epoch'))) / 60.0
  if ($MaxRunMinutes -gt 0 -and $elapsedMin -ge $MaxRunMinutes) { Stop-Run $id 'max_runtime' | Out-Null; return }
  $st = Get-LogStats (Join-Path $dir 'output.log')
  if ($RepeatStop -gt 0) {
    if ($st.Action -ge $RepeatStop) { Stop-Run $id 'loop' | Out-Null; return }
    if ($st.Denied -ge $RepeatStop) { Stop-Run $id 'denied' | Out-Null; return }
    if ($st.Text -ge (Get-FillerLimit)) { Stop-Run $id 'filler' | Out-Null; return }
  }
  if ($NoWriteStop -gt 0 -and (Test-Implementer (Read-Text (Join-Path $dir 'agent'))) -and (Test-NoWriteYet $dir) -and $elapsedMin -ge $NoWriteStop) {
    Stop-Run $id 'no_write' | Out-Null; return
  }
  $log = Join-Path $dir 'output.log'
  if ($StallMinutes -gt 0 -and (Test-Path $log)) {
    $logIdle = ((Get-Date) - (Get-Item $log).LastWriteTime).TotalMinutes
    $diffIdle = ((Get-Now) - [long](Read-Text (Join-Path $dir 'diff_changed_epoch'))) / 60.0
    if ($logIdle -ge $StallMinutes -and $diffIdle -ge $StallMinutes) { Stop-Run $id 'stalled' | Out-Null }
  }
}

function Write-Health([string]$dir) {
  $log = Join-Path $dir 'output.log'
  $lines = 0; $logIdle = '-'
  if (Test-Path $log) {
    $lines = @(Get-Content $log).Count
    $logIdle = '{0:N1}' -f ((Get-Date) - (Get-Item $log).LastWriteTime).TotalMinutes
  }
  $st = Get-LogStats $log
  $files = @(Get-StatusLines | Where-Object { $_ -notmatch ' \.work/' }).Count
  $changed = Read-Text (Join-Path $dir 'diff_changed_epoch'); if (-not $changed) { $changed = Get-Now }
  'HEALTH:'
  "  LOG_LINES: $lines · LOG_IDLE_MIN: $logIdle"
  "  DIFF_FILES: $files · DIFF_IDLE_MIN: $(Get-MinutesSince ([long]$changed))"
  "  TOP_REPEAT: $($st.Action)x `"$($st.ActionKey)`" (auto-stop at $RepeatStop; 0 = off)"
  "  DENIED: $($st.Denied) · TOP_TEXT_REPEAT: $($st.Text)x (auto-stop at $(Get-FillerLimit))"
  "  TOP_READ: $($st.Read)x `"$($st.ReadKey)`" (one file, any line range)"
  if ((Test-Implementer (Read-Text (Join-Path $dir 'agent'))) -and (Test-NoWriteYet $dir) -and -not (Test-Path (Join-Path $dir 'exit'))) {
    "  FIRST_WRITE: none yet after $(Get-MinutesSince ([long](Read-Text (Join-Path $dir 'started_epoch')))) min (auto-stop at $NoWriteStop; 0 = off)"
  }
  # Runs over ~30 minutes cost the most and are where scope piles up. Not stopped: split next time.
  $elapsed = ((Get-Now) - [long](Read-Text (Join-Path $dir 'started_epoch'))) / 60.0
  if ($LongRunMinutes -gt 0 -and -not (Test-Path (Join-Path $dir 'exit')) -and (Test-Implementer (Read-Text (Join-Path $dir 'agent'))) -and $elapsed -ge $LongRunMinutes) {
    "  LONG_RUN: $('{0:N1}' -f $elapsed) min, past $LongRunMinutes; split the remaining work into its own run next time"
  }
  $proxy = Join-Path $dir 'proxy.log'
  if (Test-Path $proxy) {
    $req = @(Select-String -Path $proxy -Pattern ' -> ').Count
    $err = @(Select-String -Path $proxy -Pattern ' -> [45][0-9][0-9]').Count
    "  MODEL_REQUESTS: $req (errors: $err)"
  }
  # Copilot prints its token totals when a run ends; every model request re-sends the whole context,
  # so cost tracks the number of requests far more than the size of the change.
  if (Test-Path $log) {
    $tok = Select-String -Path $log -Pattern '^Tokens ' -Encoding UTF8 | Select-Object -Last 1
    if ($tok) { "  TOKENS: $(($tok.Line -replace '^Tokens\s*', ''))" }
  }
  foreach ($h in (Get-HungChildren $dir)) { "  HUNG_CHILD: $h" }
  # Sustained CPU saturation (often stray processes from an earlier experiment) makes every test
  # timing and agent run look slow for no reason of their own.
  $cpu = (Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue | Measure-Object -Property LoadPercentage -Average).Average
  if ($cpu -ge 95) { "  HIGH_LOAD: CPU at $([int]$cpu)%; timings are unreliable until it drops (look for stray processes with Get-Process)" }
}

# ---- Summary -------------------------------------------------------------------------------------
function Get-Status([string]$dir) {
  $exitFile = Join-Path $dir 'exit'
  if (Test-Path $exitFile) {
    $code = Read-Text $exitFile
    if ($code -eq '0') { return @('DONE', $code) }
    if ($code -eq 'stopped') { return @('STOPPED', $code) }
    return @('FAILED', $code)
  }
  if (Test-WorkerAlive $dir) { return @('RUNNING', '') }
  return @('FAILED', 'none (worker exited without recording an exit code)')
}

function Write-Summary([string]$id) {
  $dir = Get-RunDir $id
  $st = Get-Status $dir
  $status = $st[0]; $code = $st[1]
  $model = Read-Text (Join-Path $dir 'model')
  "RUN_ID: $id"
  if ($model) { "AGENT: $(Read-Text (Join-Path $dir 'agent')) (model: $model)" } else { "AGENT: $(Read-Text (Join-Path $dir 'agent'))" }
  "STATUS: $status"
  if ($status -eq 'STOPPED') { $r = Read-Text (Join-Path $dir 'stop_reason'); if (-not $r) { $r = 'user' }; "STOP_REASON: $r" }
  elseif ($code) { "EXIT_CODE: $code" }
  "ELAPSED_MIN: $(Get-MinutesSince ([long](Read-Text (Join-Path $dir 'started_epoch'))))"
  "LOG: .work/runs/$id/output.log"
  Write-Health $dir
  if ($status -eq 'RUNNING') { "NEXT: still running. Call again with: wait $id"; return }

  'FILES_CHANGED_DURING_RUN:'
  $before = @(Get-Content (Join-Path $dir 'before') -ErrorAction SilentlyContinue)
  $started = (Get-Item (Join-Path $dir 'started')).LastWriteTime
  $any = $false
  foreach ($line in Get-StatusLines) {
    if (-not $line) { continue }
    $path = $line.Substring(3)
    if ($path -like '* -> *') { $path = $path.Substring($path.LastIndexOf(' -> ') + 4) }
    $path = $path.Trim('"')
    if ($path.StartsWith('.work/')) { continue }
    $newer = (Test-Path $path) -and ((Get-Item $path).LastWriteTime -gt $started)
    if (($before -notcontains $line) -or $newer) { "  $line"; $any = $true }
  }
  if (-not $any) { '  (none)' }
  "--- LOG TAIL (last $TailLines lines) ---"
  $log = Join-Path $dir 'output.log'
  if (Test-Path $log) { Get-Content $log -Tail $TailLines } else { '(no log written)' }
}

function Wait-Run([string]$id) {
  $dir = Get-RunDir $id
  $deadline = (Get-Now) + $WaitMinutes * 60
  while (-not (Test-Path (Join-Path $dir 'exit')) -and (Get-Now) -lt $deadline) {
    if (-not (Test-WorkerAlive $dir)) { Start-Sleep -Seconds 2; break }
    Update-Health $dir
    if (Test-Path (Join-Path $dir 'exit')) { break }
    Start-Sleep -Seconds $PollSeconds
  }
  Write-Summary $id
}

function Stop-Run([string]$id, [string]$reason = 'user') {
  $dir = Get-RunDir $id
  if (-not (Test-Path (Join-Path $dir 'exit'))) {
    Write-Text (Join-Path $dir 'stop_reason') $reason
    Write-Text (Join-Path $dir 'exit') 'stopped'
  }
  if (Test-WorkerAlive $dir) {
    & taskkill.exe /PID (Read-Text (Join-Path $dir 'pid')) /T /F *> $null
    Start-Sleep -Seconds 1
  }
  Write-Summary $id
}

function Show-Runs {
  '{0,-32} {1,-16} {2,-8} {3}' -f 'RUN_ID', 'AGENT', 'STATUS', 'ELAPSED_MIN'
  foreach ($d in (Get-ChildItem -Path $Runs -Directory | Sort-Object Name)) {
    $st = Get-Status $d.FullName
    $epoch = Read-Text (Join-Path $d.FullName 'started_epoch'); if (-not $epoch) { $epoch = Get-Now }
    '{0,-32} {1,-16} {2,-8} {3}' -f $d.Name, (Read-Text (Join-Path $d.FullName 'agent')), $st[0], (Get-MinutesSince ([long]$epoch))
  }
}

switch ($Command) {
  'start' { if (-not $Arg1 -or -not $Arg2) { Show-Usage }; $id = Start-Run $Arg1 $Arg2 $Arg3; Wait-Run $id }
  'wait' { if (-not $Arg1) { Show-Usage }; Wait-Run $Arg1 }
  'status' { if (-not $Arg1) { Show-Usage }; $d = Get-RunDir $Arg1; Update-Health $d; Write-Summary $Arg1 }
  'stop' { if (-not $Arg1) { Show-Usage }; Stop-Run $Arg1 'user' }
  'list' { Show-Runs }
  '__worker' { Invoke-Worker $Arg1 }
  default { Show-Usage }
}
