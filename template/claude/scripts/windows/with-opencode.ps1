<#
Runs a command (normally `copilot ...`) behind a private OpenCode proxy: one proxy, one
x-opencode-session, for that one invocation (Windows edition of with-opencode.sh).

  pwsh -NoProfile -File .claude/scripts/windows/with-opencode.ps1 copilot -p "Hello" --no-ask-user

Needs Node.js 18+ on PATH. The proxy listens on 127.0.0.1 only and is stopped when the command ends.
#>
$ErrorActionPreference = 'Stop'
if ($args.Count -lt 1) { [Console]::Error.WriteLine('usage: with-opencode.ps1 <command> [args...]'); exit 2 }
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$proxyScript = Join-Path $here '..\common\opencode-proxy.mjs'
if (-not $env:OPENCODE_SESSION) { $env:OPENCODE_SESSION = 'copilot-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + "-$PID" }

$tmp = Join-Path ([IO.Path]::GetTempPath()) ('opencode-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null
$portFile = Join-Path $tmp 'port'
$log = if ($env:OPENCODE_PROXY_LOG) { $env:OPENCODE_PROXY_LOG } else { Join-Path $tmp 'proxy.log' }

$node = (Get-Command node -ErrorAction SilentlyContinue | Select-Object -First 1)
if (-not $node) { [Console]::Error.WriteLine('OpenCode proxy failed to start: node not found on PATH'); exit 1 }
$proxy = Start-Process -FilePath $node.Source -ArgumentList ('"' + $proxyScript + '"') -RedirectStandardOutput $portFile -RedirectStandardError $log -WindowStyle Hidden -PassThru
try {
  for ($i = 0; $i -lt 100; $i++) {
    if ((Test-Path $portFile) -and ((Get-Item $portFile).Length -gt 0)) { break }
    Start-Sleep -Milliseconds 100
  }
  if (-not ((Test-Path $portFile) -and ((Get-Item $portFile).Length -gt 0))) {
    [Console]::Error.WriteLine('OpenCode proxy failed to start:')
    if (Test-Path $log) { Get-Content $log | ForEach-Object { [Console]::Error.WriteLine($_) } }
    exit 1
  }
  $port = (Get-Content $portFile | Select-Object -First 1).Trim()
  $env:COPILOT_PROVIDER_BASE_URL = "http://127.0.0.1:$port/v1"
  $cmd = [string]$args[0]
  $rest = @(); if ($args.Count -gt 1) { $rest = @($args[1..($args.Count - 1)]) }
  & $cmd @rest
  $code = $LASTEXITCODE
} finally {
  if ($proxy -and -not $proxy.HasExited) { & taskkill.exe /PID $proxy.Id /T /F *> $null }
  Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
exit $code
