<#
The ONLY shell command Copilot agents may run on Windows (allowed by
.github/copilot/permissions/common.flags).

  .github/copilot/scripts/windows/gateway.ps1 list
  .github/copilot/scripts/windows/gateway.ps1 <check> [args...]      checks: .github/copilot/gateway.conf
  .github/copilot/scripts/windows/gateway.ps1 git-status
  .github/copilot/scripts/windows/gateway.ps1 git-diff [<ref>] [--stat|--name-only|--name-status|--cached] [-- <path>...]
  .github/copilot/scripts/windows/gateway.ps1 git-log [<count>] [<ref>]
  .github/copilot/scripts/windows/gateway.ps1 git-show <ref> [--stat]

Runs a fixed menu, with every argument checked to stay inside the repository. Exit status: the
check's own; 124 on timeout; 2 for a refused request. Works in Windows PowerShell 5.1 and PowerShell 7.
Requires an execution policy that runs local scripts (PowerShell 7's default, RemoteSigned).
#>
$ErrorActionPreference = 'Stop'

function Refuse([string]$why) { [Console]::Error.WriteLine("gateway: refused: $why"); exit 2 }

$root = (& git rev-parse --show-toplevel 2>$null)
if (-not $root) { [Console]::Error.WriteLine('gateway: not inside a git repository'); exit 2 }
Set-Location $root
$conf = Join-Path $root '.github/copilot/gateway.conf'

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
  'Git views: git-status · git-diff [<ref>] [--stat|--name-only|--name-status|--cached] [-- <path>...] · git-log [<count>] [<ref>] · git-show <ref> [--stat]'
}

function Format-Arg([string]$a) {
  if ($a -eq '') { return '""' }
  if ($a -notmatch '[\s"]') { return $a }
  return '"' + ($a -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

function Invoke-WithTimeout([int]$secs, [string[]]$parts) {
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
  $p = Start-Process -FilePath $file -ArgumentList $argLine -NoNewWindow -PassThru
  if (-not $p.WaitForExit($secs * 1000)) {
    & taskkill.exe /PID $p.Id /T /F *> $null
    [Console]::Error.WriteLine("gateway: TIMEOUT after ${secs}s: $($parts -join ' ')")
    exit 124
  }
  $p.WaitForExit()
  exit $p.ExitCode
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
  $parts = @($e.Command -split '\s+' | Where-Object { $_ -ne '' }) + $extra
  [Console]::Error.WriteLine("gateway: $name (timeout $($e.Timeout)s): $($parts -join ' ')")
  Invoke-WithTimeout ([int]$e.Timeout) $parts
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
    if ($x -eq '--stat') { $gitArgs += '--stat' } else { Refuse "git-show option not allowed: $x" }
  }
  $gitArgs += $ref
  & git @gitArgs
  exit $LASTEXITCODE
}

if ($args.Count -eq 0) { Show-List; exit 0 }
$action = [string]$args[0]
$rest = @(); if ($args.Count -gt 1) { $rest = @($args[1..($args.Count - 1)] | ForEach-Object { [string]$_ }) }

switch ($action) {
  { $_ -in 'list', '-h', '--help' } { Show-List; exit 0 }
  'git-status' { if ($rest.Count -gt 0) { Refuse 'git-status takes no arguments' }; & git --no-pager status --short --branch; exit $LASTEXITCODE }
  'git-diff' { Invoke-GitDiff $rest }
  'git-log' { Invoke-GitLog $rest }
  'git-show' { Invoke-GitShow $rest }
  default { Invoke-Check $action $rest }
}
