<#
Portable command timeout (Windows edition of .claude/scripts/macos/with-timeout.sh).

  pwsh -NoProfile -File .claude/scripts/windows/with-timeout.ps1 <seconds> <command> [args...]

Kills the command's whole process tree on timeout. Exit status: the command's own, or 124 on
timeout, with a one-line TIMEOUT message on stderr. Works in Windows PowerShell 5.1 and PowerShell 7.
#>
$ErrorActionPreference = 'Stop'
if ($args.Count -lt 2 -or "$($args[0])" -notmatch '^\d+$') {
  [Console]::Error.WriteLine('usage: with-timeout.ps1 <seconds> <command> [args...]'); exit 2
}
$secs = [int]$args[0]
$exe = [string]$args[1]
$rest = @(); if ($args.Count -gt 2) { $rest = @($args[2..($args.Count - 1)] | ForEach-Object { [string]$_ }) }

function Format-Arg([string]$a) {
  if ($a -eq '') { return '""' }
  if ($a -notmatch '[\s"]') { return $a }
  return '"' + ($a -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

$cmd = Get-Command $exe -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $cmd) { [Console]::Error.WriteLine("with-timeout: cannot run ${exe}: not found"); exit 127 }
$path = if ($cmd.Source) { $cmd.Source } else { $cmd.Definition }
$argLine = ($rest | ForEach-Object { Format-Arg $_ }) -join ' '
if ($path -match '\.(cmd|bat)$') {
  $file = $env:ComSpec; $argLine = '/d /s /c "' + (Format-Arg $path) + ' ' + $argLine + '"'
} elseif ($path -match '\.ps1$') {
  $file = (Get-Process -Id $PID).Path; $argLine = '-NoProfile -File ' + (Format-Arg $path) + ' ' + $argLine
} else { $file = $path }

$p = Start-Process -FilePath $file -ArgumentList $argLine -NoNewWindow -PassThru
if (-not $p.WaitForExit($secs * 1000)) {
  & taskkill.exe /PID $p.Id /T /F *> $null
  [Console]::Error.WriteLine("with-timeout: TIMEOUT after ${secs}s: $exe $($rest -join ' ')")
  exit 124
}
$p.WaitForExit()
exit $p.ExitCode
