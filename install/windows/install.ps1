<#
Installs (or updates) the agentic pipeline into a target git repository — Windows.
(macOS / Linux: install/macos/install.sh, same options.)

  pwsh -NoProfile -File install\windows\install.ps1 -Config <file> -Target <repo> [-Only github] [-Force] [-DryRun]

-Config   a filled-in copy of pipeline.config.example (KEY="value" lines; PLATFORM defaults to windows)
-Only     github: install only the GitHub Copilot part (.github/agents, .github/copilot)
-Force    overwrite pipeline files that differ from the bundle (never your conventions doc, docs
          index, plans or .work/)
-DryRun   show what would be written, change nothing

It stages the template, resolves every {{PLACEHOLDER}} from the config, refuses to continue if any
placeholder is left, then copies into the target. Existing settings.json, AGENTS.md and CLAUDE.md are
merged, not replaced. Works in Windows PowerShell 5.1 and PowerShell 7.
#>
param(
  [Parameter(Mandatory = $true)][string]$Config,
  [Parameter(Mandatory = $true)][string]$Target,
  [ValidateSet('', 'github')][string]$Only = '',
  [switch]$Force,
  [switch]$DryRun
)
$ErrorActionPreference = 'Stop'
function Die([string]$m) { [Console]::Error.WriteLine("install: $m"); exit 1 }
function Say([string]$m) { Write-Output "  $m" }

$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Bundle = (Resolve-Path (Join-Path $Here '..\..')).Path
$Template = Join-Path $Bundle 'template'
$Version = if (Test-Path (Join-Path $Bundle 'VERSION')) { (Get-Content (Join-Path $Bundle 'VERSION') -Raw).Trim() } else { 'unknown' }

if (-not (Test-Path $Config)) { Die "config not found: $Config" }
if (-not (Test-Path $Target)) { Die "target not found: $Target" }
Push-Location $Target
$TargetRoot = (& git rev-parse --show-toplevel 2>$null)
Pop-Location
if (-not $TargetRoot) { Die 'target is not inside a git repository' }

# ---- Load and validate the config (bash-style KEY="value" lines) --------------------------------
$C = @{}
foreach ($line in Get-Content $Config) {
  if ($line -match '^\s*([A-Z_][A-Z0-9_]*)=(.*)$') {
    $k = $Matches[1]; $v = $Matches[2].Trim()
    if ($v -match '^"([^"]*)"') { $v = $Matches[1] }
    elseif ($v -match "^'([^']*)'") { $v = $Matches[1] }
    else { $v = ($v -replace '\s+#.*$', '').Trim() }
    $C[$k] = $v
  }
}
function Cfg([string]$k, [string]$default = '') { if ($C.ContainsKey($k) -and $C[$k] -ne '') { $C[$k] } else { $default } }
foreach ($k in 'PROJECT_NAME', 'STACK', 'BASE_BRANCH', 'LINT_CMD', 'TEST_CMD', 'PLANS_ROOT', 'CONVENTIONS_DOC', 'PLANNER_AGENT') {
  if (-not (Cfg $k)) { Die "$k is required in $Config" }
}
$Planner = Cfg 'PLANNER_AGENT'
if ($Planner -notin 'conductor', 'conductor-v2') { Die 'PLANNER_AGENT must be conductor or conductor-v2' }
$Platform = Cfg 'PLATFORM' 'windows'
if ($Platform -notin 'macos', 'windows') { Die 'PLATFORM must be macos or windows' }
$C['PLATFORM'] = $Platform
$C['PLANS_ROOT'] = (Cfg 'PLANS_ROOT').TrimEnd('/')
$C['DOCS_ROOT'] = Cfg 'DOCS_ROOT' 'docs/architecture/'
$C['DOCS_INDEX'] = Cfg 'DOCS_INDEX' ((Cfg 'DOCS_ROOT').TrimEnd('/') + '/README.md')
foreach ($pair in @(@('LONG_CMD_TIMEOUT', '300'), @('TEST_TIMEOUT', '900'), @('MAX_AGENT_MINUTES', '90'), @('WAIT_MINUTES', '15'), @('MAX_RUN_MINUTES', '120'), @('STALL_MINUTES', '30'), @('REPEAT_STOP', '40'))) {
  $C[$pair[0]] = Cfg $pair[0] $pair[1]
  if ($C[$pair[0]] -notmatch '^\d+$') { Die "$($pair[0]) must be a whole number (got '$($C[$pair[0]])')" }
}
$wrapper = Cfg 'COPILOT_WRAPPER'
if ($Platform -eq 'windows') {
  $C['RUNNER'] = 'pwsh -NoProfile -File .claude/scripts/windows/run-agent.ps1'
  $C['STATS'] = 'pipeline-stats (macOS/Linux only for now: run it from Git Bash)'
  $C['TIMEOUT_WRAPPER'] = 'pwsh -NoProfile -File .claude/scripts/windows/with-timeout.ps1'
  $C['GATEWAY'] = '.github/copilot/scripts/windows/gateway.ps1'
  if ($wrapper -eq 'with-opencode.sh') { $wrapper = 'with-opencode.ps1' }
  if ($wrapper -notin '', 'with-opencode.ps1') { Die 'COPILOT_WRAPPER must be empty or with-opencode.ps1' }
} else {
  $C['RUNNER'] = 'bash .claude/scripts/macos/run-agent.sh'
  $C['STATS'] = 'bash .claude/scripts/macos/pipeline-stats.sh'
  $C['TIMEOUT_WRAPPER'] = 'bash .claude/scripts/macos/with-timeout.sh'
  $C['GATEWAY'] = '.github/copilot/scripts/macos/gateway.sh'
  if ($wrapper -eq 'with-opencode.ps1') { $wrapper = 'with-opencode.sh' }
  if ($wrapper -notin '', 'with-opencode.sh') { Die 'COPILOT_WRAPPER must be empty or with-opencode.sh' }
}
$C['COPILOT_WRAPPER'] = $wrapper
$C['PLANS_GLOB'] = $C['PLANS_ROOT'] + '/**'
$C['DOCS_GLOB'] = $C['DOCS_ROOT'].TrimEnd('/') + '/**'
# Probe files an agent may remove with `gateway delete-scratch`: untracked <test root>/zz_<name>.
$testRoot = (Cfg 'TEST_ROOT').TrimEnd('/')
$C['SCRATCH_PREFIX'] = if ($testRoot) { "$testRoot/zz_" } else { 'zz_' }
foreach ($r in 'PLANNER', 'DEVELOPER', 'REVIEWER') { $C["${r}_MODEL_RAW"] = Cfg "${r}_MODEL" }

# Gateway checks: lint/typecheck/test/build, then GATEWAY_EXTRA (name|seconds|command[|options]; ';').
$extras = @((Cfg 'GATEWAY_EXTRA') -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$extraNames = @()
foreach ($e in $extras) {
  $f = $e.Split('|')
  if ($f.Count -lt 3 -or $f[0].Trim() -notmatch '^[a-z][a-z0-9-]*$' -or $f[1].Trim() -notmatch '^\d+$' -or -not $f[2].Trim()) {
    Die "bad GATEWAY_EXTRA entry '$e' (expected name|seconds|command[|options])"
  }
  if ($f[0].Trim() -eq 'list' -or $f[0].Trim().StartsWith('git-')) { Die "GATEWAY_EXTRA name '$($f[0].Trim())' is reserved" }
  $extraNames += $f[0].Trim()
}
$entries = @()
foreach ($d in @(@('lint', 'LONG_CMD_TIMEOUT', 'LINT_CMD'), @('typecheck', 'LONG_CMD_TIMEOUT', 'TYPECHECK_CMD'), @('test', 'TEST_TIMEOUT', 'TEST_CMD'), @('build', 'LONG_CMD_TIMEOUT', 'BUILD_CMD'))) {
  $cmd = Cfg $d[2]
  if (-not $cmd -or $extraNames -contains $d[0]) { continue }
  $entries += ('{0,-10} | {1,-4} | {2}' -f $d[0], $C[$d[1]], $cmd)
}
$C['GATEWAY_ENTRIES'] = (($entries + $extras) -join "`n")

function EmptyText([string]$k) {
  if ($k -eq 'COPILOT_WRAPPER' -or $k -like '*_MODEL_RAW') { return '' }
  if ($k -eq 'INVARIANT_CHECKS') { return 'none configured yet - add them to pipeline.config and re-run the installer' }
  return '(not used in this project)'
}

# ---- Stage ---------------------------------------------------------------------------------------
$Stage = Join-Path ([IO.Path]::GetTempPath()) ('pipeline-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Stage | Out-Null
try {
  $other = if ($Planner -eq 'conductor') { 'conductor-v2' } else { 'conductor' }
  function Copy-Into([string]$from, [string]$to) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $to) | Out-Null
    Copy-Item -Recurse -Force $from $to
  }
  Copy-Into (Join-Path $Template 'github/agents') (Join-Path $Stage '.github/agents')
  Copy-Into (Join-Path $Template 'github/copilot/permissions') (Join-Path $Stage '.github/copilot/permissions')
  Copy-Into (Join-Path $Template 'github/copilot/gateway.conf') (Join-Path $Stage '.github/copilot/gateway.conf')
  Copy-Into (Join-Path $Template 'github/copilot/pr-scope-budget.md') (Join-Path $Stage '.github/copilot/pr-scope-budget.md')
  Copy-Into (Join-Path $Template 'github/copilot/agent-rules.md') (Join-Path $Stage '.github/copilot/agent-rules.md')
  Copy-Into (Join-Path $Template "github/copilot/scripts/$Platform") (Join-Path $Stage ".github/copilot/scripts/$Platform")
  Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $Stage ".github/agents/$other.agent.md"), (Join-Path $Stage ".github/copilot/permissions/$other.flags")
  if (-not $Only) {
    Copy-Into (Join-Path $Template 'claude/agents') (Join-Path $Stage '.claude/agents')
    Copy-Into (Join-Path $Template 'claude/commands') (Join-Path $Stage '.claude/commands')
    Copy-Into (Join-Path $Template 'claude/skills') (Join-Path $Stage '.claude/skills')
    Copy-Into (Join-Path $Template "claude/scripts/$Platform") (Join-Path $Stage ".claude/scripts/$Platform")
    Copy-Into (Join-Path $Template 'claude/scripts/common') (Join-Path $Stage '.claude/scripts/common')
    Copy-Into (Join-Path $Template 'claude/pipeline.env') (Join-Path $Stage '.claude/pipeline.env')
    Copy-Into (Join-Path $Template 'claude/settings.json') (Join-Path $Stage '.claude/settings.json')
    Remove-Item -Force -ErrorAction SilentlyContinue (Join-Path $Stage ".claude/agents/$other.md")
    Copy-Into (Join-Path $Template 'AGENTS.pipeline.md') (Join-Path $Stage 'AGENTS.pipeline.md')
    Copy-Into (Join-Path $Template 'docs/conventions.md') (Join-Path $Stage 'docs/conventions.md')
    Copy-Into (Join-Path $Template 'docs/architecture-index.md') (Join-Path $Stage 'docs/architecture-index.md')
  }

  # Resolve placeholders.
  $unused = @()
  $files = Get-ChildItem -Path $Stage -Recurse -File
  $utf8 = New-Object Text.UTF8Encoding($false)
  foreach ($file in $files) {
    $text = [IO.File]::ReadAllText($file.FullName)
    $text = [regex]::Replace($text, '\{\{([A-Z_]+)\}\}', {
        param($m)
        $k = $m.Groups[1].Value
        $v = Cfg $k
        if (-not $v -and $C.ContainsKey($k)) { $v = $C[$k] }
        if (-not $v) {
          $v = EmptyText $k
          if ($k -ne 'COPILOT_WRAPPER' -and $k -notlike '*_MODEL_RAW' -and $script:unused -notcontains $k) { $script:unused += $k }
        }
        return $v
      })
    [IO.File]::WriteAllText($file.FullName, $text, $utf8)
  }
  $left = Select-String -Path ($files | ForEach-Object FullName) -Pattern '\{\{[A-Z_]+\}\}' -ErrorAction SilentlyContinue
  if ($left) { Die ("unresolved placeholders remain:`n" + (($left | ForEach-Object { $_.ToString() }) -join "`n")) }
  if (-not $Only) {
    try { $null = Get-Content (Join-Path $Stage '.claude/settings.json') -Raw | ConvertFrom-Json }
    catch { Die 'settings.json is not valid JSON after substitution (a command in the config contains a double quote?)' }
  }

  # ---- Plan the copy -----------------------------------------------------------------------------
  Set-Location $TargetRoot
  $writes = @(); $conflicts = @()
  foreach ($file in (Get-ChildItem -Path $Stage -Recurse -File)) {
    $rel = $file.FullName.Substring($Stage.Length + 1).Replace('\', '/')
    if ($rel -eq 'AGENTS.pipeline.md' -or $rel.StartsWith('docs/') -or $rel -eq '.claude/settings.json') { continue }
    if ((Test-Path $rel) -and ((Get-FileHash $rel).Hash -ne (Get-FileHash $file.FullName).Hash)) { $conflicts += $rel }
    $writes += $rel
  }
  if ($conflicts.Count -gt 0 -and -not $Force) {
    Die ("these files exist and differ from the bundle (re-run with -Force to overwrite):`n    " + ($conflicts -join "`n    "))
  }
  $onlyNote = if ($Only) { ", only $Only" } else { '' }
  Write-Output "Installing agentic pipeline $Version ($Platform$onlyNote) into $TargetRoot"
  if ($DryRun) {
    Write-Output '(dry run - nothing written)'
    foreach ($rel in $writes) { Say "write $rel" }
    return
  }

  foreach ($rel in $writes) {
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $rel) | Out-Null
    Copy-Item -Force (Join-Path $Stage $rel) $rel
  }
  Say "Copilot agents, permission profiles and gateway -> .github/ (planner: $Planner)"

  if (-not $Only) {
    Say 'Claude agents, commands, skills, scripts and pipeline.env -> .claude/'
    $newSettings = Get-Content (Join-Path $Stage '.claude/settings.json') -Raw | ConvertFrom-Json
    if (-not (Test-Path '.claude/settings.json')) {
      Copy-Item (Join-Path $Stage '.claude/settings.json') '.claude/settings.json'
      Say 'created .claude/settings.json'
    } else {
      $cur = Get-Content '.claude/settings.json' -Raw | ConvertFrom-Json
      if (-not $cur.env) { $cur | Add-Member -NotePropertyName env -NotePropertyValue ([pscustomobject]@{}) }
      foreach ($p in $newSettings.env.PSObject.Properties) {
        if (-not ($cur.env.PSObject.Properties.Name -contains $p.Name)) { $cur.env | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value }
      }
      if (-not $cur.permissions) { $cur | Add-Member -NotePropertyName permissions -NotePropertyValue ([pscustomobject]@{}) }
      foreach ($key in 'allow', 'deny') {
        $have = @(); if ($cur.permissions.$key) { $have = @($cur.permissions.$key) }
        foreach ($rule in $newSettings.permissions.$key) { if ($have -notcontains $rule) { $have += $rule } }
        if ($cur.permissions.PSObject.Properties.Name -contains $key) { $cur.permissions.$key = $have }
        else { $cur.permissions | Add-Member -NotePropertyName $key -NotePropertyValue $have }
      }
      [IO.File]::WriteAllText((Join-Path $TargetRoot '.claude/settings.json'), ($cur | ConvertTo-Json -Depth 10) + "`n", $utf8)
      Say 'merged permissions into existing .claude/settings.json'
    }

    $begin = '<!-- agentic-pipeline:begin - managed by the installer; change pipeline.config and re-run -->'
    $block = $begin + "`n" + [IO.File]::ReadAllText((Join-Path $Stage 'AGENTS.pipeline.md')).TrimEnd() + "`n<!-- agentic-pipeline:end -->"
    if ((Test-Path 'AGENTS.md') -and (Select-String -Path 'AGENTS.md' -SimpleMatch 'agentic-pipeline:begin' -Quiet)) {
      $t = [IO.File]::ReadAllText((Join-Path $TargetRoot 'AGENTS.md'))
      $t = [regex]::Replace($t, '(?s)<!-- agentic-pipeline:begin.*?<!-- agentic-pipeline:end -->', { param($m) $block })
      [IO.File]::WriteAllText((Join-Path $TargetRoot 'AGENTS.md'), $t, $utf8)
      Say 'updated the pipeline block in AGENTS.md'
    } elseif (Test-Path 'AGENTS.md') {
      Add-Content -Path 'AGENTS.md' -Value ("`n" + $block)
      Say 'appended the pipeline block to AGENTS.md'
    } else {
      [IO.File]::WriteAllText((Join-Path $TargetRoot 'AGENTS.md'), "# $(Cfg 'PROJECT_NAME')`n`n$block`n", $utf8)
      Say 'created AGENTS.md'
    }
    if (-not (Select-String -Path 'AGENTS.md' -SimpleMatch '## Known long-running or hanging commands' -Quiet)) {
      Add-Content -Path 'AGENTS.md' -Value @"

## Known long-running or hanging commands

<!-- Yours to edit; the installer never rewrites this section. List commands that run long or have
     hung, the timeout to use, and the known cause. The runner adds this section to every Copilot
     agent prompt. For Copilot agents, also add such commands as gateway
     checks (GATEWAY_EXTRA in pipeline.config) with a timeout. -->
"@
      Say "added the 'Known long-running or hanging commands' section to AGENTS.md (yours to edit)"
    }

    if (Test-Path 'CLAUDE.md') {
      if (-not (Select-String -Path 'CLAUDE.md' -Pattern '^@AGENTS\.md\s*$' -Quiet)) { Add-Content -Path 'CLAUDE.md' -Value "`n@AGENTS.md"; Say "added '@AGENTS.md' import to CLAUDE.md" }
    } else {
      [IO.File]::WriteAllText((Join-Path $TargetRoot 'CLAUDE.md'), "# $(Cfg 'PROJECT_NAME')`n`n@AGENTS.md`n", $utf8)
      Say 'created CLAUDE.md (imports AGENTS.md)'
    }

    $conv = Cfg 'CONVENTIONS_DOC'
    if (-not (Test-Path $conv)) { Copy-Into (Join-Path $Stage 'docs/conventions.md') $conv; Say "created $conv (skeleton - fill it in before the first run)" }
    $idx = $C['DOCS_INDEX']
    if (-not (Test-Path $idx)) { Copy-Into (Join-Path $Stage 'docs/architecture-index.md') $idx; Say "created $idx (skeleton)" }
    [IO.File]::WriteAllText((Join-Path $TargetRoot '.claude/pipeline.version'), "agentic-pipeline $Version ($Platform) installed $(Get-Date -Format yyyy-MM-dd) from $(Split-Path -Leaf $Config)`n", $utf8)
  }

  $plans = $C['PLANS_ROOT']
  New-Item -ItemType Directory -Force -Path $plans | Out-Null
  if (-not (Get-ChildItem -Force $plans)) { New-Item -ItemType File -Path (Join-Path $plans '.gitkeep') | Out-Null }
  if (-not (Test-Path '.gitignore')) { New-Item -ItemType File -Path '.gitignore' | Out-Null }
  if (-not (Select-String -Path '.gitignore' -Pattern '^/?\.work/?$' -Quiet)) {
    Add-Content -Path '.gitignore' -Value "`n# agentic pipeline scratch (briefs, run logs)`n.work/"
    Say 'added .work/ to .gitignore'
  }
  New-Item -ItemType Directory -Force -Path '.work' | Out-Null
  if (-not (Test-Path '.work/friction.md')) { [IO.File]::WriteAllText((Join-Path $TargetRoot '.work/friction.md'), "# Friction log`n`n", $utf8) }
  foreach ($d in '.claude/agents', '.github/agents') {
    if (Test-Path "$d/README.md") { Say "WARNING: $d/README.md exists - Copilot CLI treats it as a malformed agent; move it out" }
  }

  Write-Output ''
  Write-Output 'Done. Next:'
  if (-not $Only) {
    Write-Output "  1. Fill in $(Cfg 'CONVENTIONS_DOC') and the 'Known long-running or hanging commands' section of AGENTS.md."
    Write-Output '  2. Set up the Copilot model provider (README section 3) and run the smoke test (README section 5).'
    Write-Output '  3. Review and commit: git add .claude .github AGENTS.md CLAUDE.md .gitignore docs'
  } else {
    Write-Output '  1. Point your runner at .github/copilot/permissions/ (the bundle''s runner does) and remove --allow-all-tools.'
    Write-Output '  2. Review and commit: git add .github'
  }
  Write-Output "  Gateway checks for Copilot agents: $($C['GATEWAY']) list"
  if ($unused.Count -gt 0) {
    Write-Output ''
    Write-Output ("Marked '(not used in this project)': " + ($unused -join ' '))
    Write-Output '  Agents skip rules about these. If one does exist in your project, set it in the config and re-run.'
  }
} finally {
  Set-Location $Bundle
  Remove-Item -Recurse -Force $Stage -ErrorAction SilentlyContinue
}
