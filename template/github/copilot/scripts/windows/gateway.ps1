<#
The ONLY shell command Copilot agents may run on Windows (allowed by
.github/copilot/permissions/common.flags).

  .github/copilot/scripts/windows/gateway.ps1 list
  .github/copilot/scripts/windows/gateway.ps1 <check> [args...]      checks: .github/copilot/gateway.conf
  .github/copilot/scripts/windows/gateway.ps1 git-status
  .github/copilot/scripts/windows/gateway.ps1 git-diff [<ref>] [--stat|--name-only|--name-status|--cached] [-- <path>...]
  .github/copilot/scripts/windows/gateway.ps1 git-log [<count>] [<ref>]
  .github/copilot/scripts/windows/gateway.ps1 git-show <ref> [--stat|--name-only|--name-status]
  .github/copilot/scripts/windows/gateway.ps1 delete-scratch <path>   removes an untracked probe file
  .github/copilot/scripts/windows/gateway.ps1 prove-red <ref> <check> [args...] [-- <files...>]
      runs <check> on a temporary checkout of <ref> with your versions of <files> (default: the args
      that are files) carried over: a new or changed test proves something only if it FAILS there

Runs a fixed menu, with every argument checked to stay inside the repository. Exit status: the
check's own; 124 on timeout; 2 for a refused request.

Output: a check that prints more than $SummaryOver lines or $SummaryBytes bytes is saved whole under .work/gateway/ and
shown as a summary (first lines, every line that looks like a failure, the last lines, and the path
of the full log). Every model request re-sends the agent's whole context, so a 40 KB lint dump that
the agent then re-reads in chunks costs far more than the check itself. A check with the
`full-output` option in gateway.conf always prints everything. Works in Windows PowerShell 5.1 and PowerShell 7.
Requires an execution policy that runs local scripts (PowerShell 7's default, RemoteSigned).
#>
$ErrorActionPreference = 'Stop'

function Refuse([string]$why) { [Console]::Error.WriteLine("gateway: refused: $why"); exit 2 }

$root = (& git rev-parse --show-toplevel 2>$null)
if (-not $root) { [Console]::Error.WriteLine('gateway: not inside a git repository'); exit 2 }
Set-Location $root
$conf = Join-Path $root '.github/copilot/gateway.conf'
$LogDir = Join-Path $root '.work/gateway'
$MainRoot = $root
# prove-red re-runs this script inside a temporary checkout; it keeps the main checkout's checks and
# log folder. (An agent cannot set these: its shell permission only matches the gateway's own path.)
if ($env:GATEWAY_INNER -eq '1') { $conf = $env:GATEWAY_CONF; $LogDir = $env:GATEWAY_LOG_DIR; $MainRoot = $env:GATEWAY_MAIN_ROOT }
$SummaryOver = 200
$SummaryBytes = 16000   # long lines matter too: 196 lint notices are only ~200 lines but 37 KB
# Untracked files whose path starts with this may be removed with delete-scratch (set by the installer).
$ScratchPrefix = '{{SCRATCH_PREFIX}}'

function Test-Arg([string]$a) {
  if ($a -match '^[/\\~]') { Refuse "absolute or home path: $a" }
  if ($a -match '^[A-Za-z]:') { Refuse "drive path: $a" }
  if ($a -match '=([/\\~]|[A-Za-z]:)') { Refuse "absolute or home path in option: $a" }
  if ($a -match '(^|[/\\=])\.\.([/\\]|$)') { Refuse "parent-directory path: $a" }
  # cmd.exe re-parses .cmd/.bat command lines; refuse its metacharacters outright.
  if ($a -match '[&|<>^%!"`\r\n]') { Refuse "special characters in argument: $a" }
}

function Test-Ref([string]$r) {
  if ($r.StartsWith('-')) { Refuse "a ref cannot start with '-': $r" }
  if ($r -match '[&|<>^%!"`\s]') { Refuse "bad ref: $r" }
  & git rev-parse --verify --quiet "$r^{commit}" *> $null
  if ($LASTEXITCODE -ne 0) { Refuse "not a commit in this repository: $r" }
}

function Get-Entries {
  if (-not (Test-Path $conf)) { Refuse "missing $conf" }
  Get-Content $conf | Where-Object { $_ -notmatch '^\s*(#|$)' } | ForEach-Object {
    $f = $_.Split('|')
    [pscustomobject]@{
      Name    = $f[0].Trim()
      Timeout = if ($f.Count -gt 1) { $f[1].Trim() } else { '' }
      Command = if ($f.Count -gt 2) { $f[2].Trim() } else { '' }
      Options = if ($f.Count -gt 3) { $f[3].Trim() } else { '' }
    }
  }
}

function Show-List {
  'Checks (gateway.conf):'
  foreach ($e in Get-Entries) {
    $opt = if ($e.Options) { "  [$($e.Options)]" } else { '' }
    '  {0,-14} {1,5}s  {2}{3}' -f $e.Name, $e.Timeout, $e.Command, $opt
  }
  'Git views: git-status · git-diff [<ref>] [--stat|--name-only|--name-status|--cached] [-- <path>...] · git-log [<count>] [<ref>] · git-show <ref> [--stat|--name-only|--name-status]'
  'Proof: prove-red <ref> <check> [args...] [-- <files...>] runs a check on <ref> (e.g. HEAD) with your test files carried over; a guard must FAIL there'
  "Cleanup: delete-scratch ${ScratchPrefix}<name> (an untracked probe file you created)"
  "Output over $SummaryOver lines or $([int]($SummaryBytes / 1000)) KB is summarised; the full log path is printed (read it with your file tool)."
}

function Format-Arg([string]$a) {
  if ($a -eq '') { return '""' }
  if ($a -notmatch '[\s"]') { return $a }
  return '"' + ($a -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

# Prints a check's output: whole when short, otherwise a summary that points at the full log.
function Write-CheckOutput([string]$exe, [string]$log) {
  $l = @(Get-Content -Path $log -Encoding UTF8 -ErrorAction SilentlyContinue)
  $cut = { param($s) if ($s.Length -gt 300) { $s.Substring(0, 300) + ' ...' } else { $s } }
  $size = ($l | Measure-Object -Property Length -Sum).Sum + $l.Count
  if ($l.Count -le $SummaryOver -and $size -le $SummaryBytes) { $l | ForEach-Object { & $cut $_ }; return }
  $rel = $log.Substring($MainRoot.Length).TrimStart('\', '/') -replace '\\', '/'
  $fail = '(?i)\b(error|errors|fail|failed|failure|failing|exception|panic|traceback|assert\w*|expected|actual|timed? ?out)\b|\[E\]|' + [char]0x2717
  $hits = @(0..($l.Count - 1) | Where-Object { $l[$_] -match $fail })
  "gateway: $exe printed $($l.Count) lines; full output: $rel"
  '--- first 5 lines'; $l[0..([Math]::Min(4, $l.Count - 1))] | ForEach-Object { & $cut $_ }
  $shown = @($hits | Select-Object -First 120)
  $note = if ($hits.Count -gt 120) { ', first 120' } else { '' }
  "--- lines that look like failures ($($hits.Count))$note"
  foreach ($i in $shown) { '{0,6}: {1}' -f ($i + 1), (& $cut $l[$i]) }
  '--- last 40 lines'; $l[([Math]::Max(0, $l.Count - 40))..($l.Count - 1)] | ForEach-Object { & $cut $_ }
  "--- full output: $rel (read it with your file tool, by line range)"
}

function Invoke-WithTimeout([int]$secs, [string[]]$parts, [string]$log = '') {
  $exe = $parts[0]
  $rest = @(); if ($parts.Count -gt 1) { $rest = $parts[1..($parts.Count - 1)] }
  $cmd = Get-Command $exe -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $cmd) { [Console]::Error.WriteLine("gateway: cannot find $exe"); exit 127 }
  $path = if ($cmd.Source) { $cmd.Source } else { $cmd.Definition }
  $argLine = ($rest | ForEach-Object { Format-Arg $_ }) -join ' '
  if ($path -match '\.(cmd|bat)$') {
    $file = $env:ComSpec
    $argLine = '/d /s /c "' + (Format-Arg $path) + ' ' + $argLine + '"'
  } elseif ($path -match '\.ps1$') {
    $file = (Get-Process -Id $PID).Path
    $argLine = '-NoProfile -File ' + (Format-Arg $path) + ' ' + $argLine
  } else {
    $file = $path
  }
  if (-not $log) {
    $p = Start-Process -FilePath $file -ArgumentList $argLine -NoNewWindow -PassThru
  } else {
    # Start-Process cannot send both streams to one file; join them afterwards (stdout, then stderr).
    $p = Start-Process -FilePath $file -ArgumentList $argLine -NoNewWindow -PassThru `
      -RedirectStandardOutput "$log.out" -RedirectStandardError "$log.err"
  }
  $timedOut = -not $p.WaitForExit($secs * 1000)
  if ($timedOut) { & taskkill.exe /PID $p.Id /T /F *> $null }
  $p.WaitForExit()
  if ($log) {
    Get-Content "$log.out", "$log.err" -Encoding UTF8 -ErrorAction SilentlyContinue | Set-Content $log -Encoding UTF8
    Remove-Item "$log.out", "$log.err" -ErrorAction SilentlyContinue
    Write-CheckOutput $exe $log
  }
  # The exit code goes in a script variable: anything returned would mix into the printed output.
  if ($timedOut) {
    [Console]::Error.WriteLine("gateway: TIMEOUT after ${secs}s: $($parts -join ' ')")
    $script:CheckExit = 124
  } else {
    $script:CheckExit = $p.ExitCode
  }
}

# Tracked files missing from the working tree.
function Get-DeletedTracked { @(& git -c core.quotepath=off ls-files --deleted 2>$null | Where-Object { $_ }) }

# A check runs code the agent wrote (a test can do anything), so it is the one way around the
# "no deletions" policy. Any tracked file a check deleted is restored, and the check fails.
function Undo-Deletions([string]$name, [string[]]$before) {
  $gone = @(Get-DeletedTracked | Where-Object { $before -notcontains $_ })
  if ($gone.Count -eq 0) { return $true }
  foreach ($f in $gone) { & git checkout -- $f 2>$null | Out-Null }
  [Console]::Error.WriteLine("gateway: REVERTED: '$name' deleted tracked files, which agents may not do through a check:")
  foreach ($f in $gone) { [Console]::Error.WriteLine("  $f") }
  [Console]::Error.WriteLine('List the deletions the work needs under "Governor actions" in your final report; the governor makes them.')
  return $false
}

function Invoke-Check([string]$name, [string[]]$extra) {
  $e = Get-Entries | Where-Object { $_.Name -eq $name } | Select-Object -First 1
  if (-not $e) { [Console]::Error.WriteLine("gateway: unknown check '$name'."); Show-List | ForEach-Object { [Console]::Error.WriteLine($_) }; exit 2 }
  if ($e.Timeout -notmatch '^\d+$') { Refuse "bad timeout for '$name' in gateway.conf" }
  if (-not $e.Command) { Refuse "no command for '$name' in gateway.conf" }
  foreach ($a in $extra) { Test-Arg $a }
  if ($e.Options -match 'requires-args' -and $extra.Count -eq 0) {
    Refuse "'$name' needs explicit file arguments (it must never run on the whole tree)"
  }
  if ($e.Options -match 'new-files-only') {
    foreach ($a in $extra) {
      if ($a.StartsWith('-')) { continue }
      & git ls-files --error-unmatch -- $a *> $null
      if ($LASTEXITCODE -eq 0) { Refuse "'$name' only runs on files this change created; '$a' is already tracked by git. Edit existing files with small edits instead" }
    }
  }
  $parts = @($e.Command -split '\s+' | Where-Object { $_ -ne '' }) + $extra
  [Console]::Error.WriteLine("gateway: $name (timeout $($e.Timeout)s): $($parts -join ' ')")
  $before = Get-DeletedTracked
  $script:CheckExit = 0
  if ($e.Options -match 'full-output') {
    Invoke-WithTimeout ([int]$e.Timeout) $parts
  } else {
    $dir = $LogDir
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Get-ChildItem $dir -Filter '*.log' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-1) } | Remove-Item -ErrorAction SilentlyContinue
    $log = Join-Path $dir ('{0}-{1}-{2}.log' -f $name, (Get-Date -Format 'yyyyMMdd-HHmmss'), $PID)
    Invoke-WithTimeout ([int]$e.Timeout) $parts $log
  }
  $code = $script:CheckExit
  if (-not (Undo-Deletions $name $before) -and $code -eq 0) { $code = 3 }
  exit $code
}

# Lets an agent remove its OWN probe file: only an untracked regular file under $ScratchPrefix.
function Remove-Scratch([string[]]$a) {
  if ($a.Count -ne 1) { Refuse 'delete-scratch takes exactly one path' }
  $p = $a[0] -replace '\\', '/'
  Test-Arg $p
  $name = if ($p.StartsWith($ScratchPrefix)) { $p.Substring($ScratchPrefix.Length) } else { '' }
  if ($name -notmatch '^[A-Za-z0-9_.-]+$') { Refuse "delete-scratch only removes ${ScratchPrefix}<name> probe files: $p" }
  & git ls-files --error-unmatch -- $p *> $null
  if ($LASTEXITCODE -eq 0) { Refuse "delete-scratch will not remove a tracked file: $p" }
  $item = Get-Item -LiteralPath $p -ErrorAction SilentlyContinue
  if (-not $item -or $item.PSIsContainer -or $item.LinkType) { Refuse "no such file: $p" }
  Remove-Item -LiteralPath $p
  [Console]::Error.WriteLine("gateway: removed $p")
  exit 0
}

function Invoke-GitDiff([string[]]$a) {
  $opts = @(); $ref = $null; $paths = @(); $afterDashes = $false
  foreach ($x in $a) {
    if ($afterDashes) { Test-Arg $x; $paths += $x; continue }
    switch -Regex ($x) {
      '^--$' { $afterDashes = $true; continue }
      '^--(stat|name-only|name-status|cached|staged)$' { $opts += $x; continue }
      '^-' { Refuse "git-diff option not allowed: $x" }
      default { if ($ref) { Refuse 'git-diff takes at most one ref' }; Test-Ref $x; $ref = $x }
    }
  }
  $gitArgs = @('--no-pager', 'diff') + $opts
  if ($ref) { $gitArgs += $ref }
  $gitArgs += '--'
  $gitArgs += $paths
  & git @gitArgs
  exit $LASTEXITCODE
}

function Invoke-GitLog([string[]]$a) {
  $count = 20; $ref = $null
  foreach ($x in $a) {
    if ($x -match '^\d+$') { $count = [int]$x; if ($count -gt 500) { Refuse 'git-log count above 500' } }
    else { Test-Ref $x; $ref = $x }
  }
  $gitArgs = @('--no-pager', 'log', '--oneline', '-n', "$count")
  if ($ref) { $gitArgs += $ref }
  & git @gitArgs
  exit $LASTEXITCODE
}

function Invoke-GitShow([string[]]$a) {
  if ($a.Count -lt 1) { Refuse 'git-show needs a ref' }
  $ref = $a[0]; Test-Ref $ref
  $gitArgs = @('--no-pager', 'show')
  foreach ($x in ($a | Select-Object -Skip 1)) {
    if ($x -in '--stat', '--name-only', '--name-status') { $gitArgs += $x } else { Refuse "git-show option not allowed: $x" }
  }
  $gitArgs += $ref
  & git @gitArgs
  exit $LASTEXITCODE
}

if ($args.Count -eq 0) { Show-List; exit 0 }
$action = [string]$args[0]
$rest = @(); if ($args.Count -gt 1) { $rest = @($args[1..($args.Count - 1)] | ForEach-Object { [string]$_ }) }

# Shows that new or changed tests detect the change: runs <check> on a temporary checkout of <ref>
# (typically HEAD, or the base commit the brief names) with the agent's versions of the test files
# carried over. Green there means the tests pass without the change, so they prove nothing.
function Invoke-ProveRed([string[]]$a) {
  if ($a.Count -lt 2) { Refuse 'usage: prove-red <ref> <check> [args...] [-- <files to carry over...>]' }
  $ref = $a[0]; $name = $a[1]
  Test-Ref $ref
  if ($name -in 'prove-red', 'delete-scratch', 'list', 'base-setup' -or $name -like 'git-*') { Refuse "prove-red runs a check from gateway.conf, not '$name'" }
  if (-not (Get-Entries | Where-Object { $_.Name -eq $name })) { Refuse "unknown check '$name'" }
  $checkArgs = @(); $carry = @(); $split = $false
  foreach ($x in ($a | Select-Object -Skip 2)) {
    if ($split) { $carry += $x; continue }
    if ($x -eq '--') { $split = $true; continue }
    $checkArgs += $x
  }
  if (-not $split) { $carry = @($checkArgs | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }) }
  if ($carry.Count -eq 0) { Refuse "name the test files to carry over (after '--', or as file arguments)" }
  foreach ($x in $checkArgs) { Test-Arg $x }
  foreach ($x in $carry) { Test-Arg $x; if (-not (Test-Path -LiteralPath $x -PathType Leaf)) { Refuse "not a file: $x" } }

  New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
  $wt = Join-Path $LogDir "base-$PID"
  & git worktree add --detach -q $wt $ref *> $null
  if ($LASTEXITCODE -ne 0) { Refuse "could not check out $ref" }
  $code = 0
  try {
    foreach ($x in $carry) {
      $dest = Join-Path $wt $x
      New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
      Copy-Item -LiteralPath $x -Destination $dest -Force
    }
    $env:GATEWAY_INNER = '1'; $env:GATEWAY_CONF = $conf; $env:GATEWAY_LOG_DIR = $LogDir; $env:GATEWAY_MAIN_ROOT = $MainRoot
    $shell = (Get-Process -Id $PID).Path
    [Console]::Error.WriteLine("gateway: prove-red: '$name' on $ref with your versions of: $($carry -join ' ')")
    Push-Location $wt
    try {
      if (Get-Entries | Where-Object { $_.Name -eq 'base-setup' }) {
        & $shell -NoProfile -File $PSCommandPath base-setup *> $null
        if ($LASTEXITCODE -ne 0) { [Console]::Error.WriteLine("gateway: prove-red: base-setup failed on $ref"); $code = -2 }
      }
      if ($code -eq 0) { & $shell -NoProfile -File $PSCommandPath $name @checkArgs; $code = $LASTEXITCODE }
    } finally { Pop-Location }
  } finally {
    Remove-Item Env:GATEWAY_INNER, Env:GATEWAY_CONF, Env:GATEWAY_LOG_DIR, Env:GATEWAY_MAIN_ROOT -ErrorAction SilentlyContinue
    & git -C $MainRoot worktree remove --force $wt *> $null
    if (Test-Path $wt) { Remove-Item -Recurse -Force $wt -ErrorAction SilentlyContinue }
    & git -C $MainRoot worktree prune *> $null
  }
  if ($code -eq -2) { exit 2 }
  if ($code -eq 124) { [Console]::Error.WriteLine("gateway: prove-red: TIMEOUT on $ref"); exit 124 }
  if ($code -eq 0) {
    [Console]::Error.WriteLine("gateway: prove-red: GREEN AT ${ref}: these tests pass without your change, so they do not detect it. Strengthen them.")
    exit 1
  }
  [Console]::Error.WriteLine("gateway: prove-red: RED AT $ref (exit $code). It proves the guard only if an assertion fails for the reason the test guards; a compile or load error means the test could not run there (use a mutation instead).")
  exit 0
}

switch ($action) {
  { $_ -in 'list', '-h', '--help' } { Show-List; exit 0 }
  'git-status' { if ($rest.Count -gt 0) { Refuse 'git-status takes no arguments' }; & git --no-pager status --short --branch; exit $LASTEXITCODE }
  'git-diff' { Invoke-GitDiff $rest }
  'git-log' { Invoke-GitLog $rest }
  'git-show' { Invoke-GitShow $rest }
  'delete-scratch' { Remove-Scratch $rest }
  'prove-red' { Invoke-ProveRed $rest }
  default { Invoke-Check $action $rest }
}
