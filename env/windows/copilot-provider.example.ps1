# Copilot CLI model provider — Windows environment. Pick ONE option and run its lines once in
# PowerShell: [Environment]::SetEnvironmentVariable(..., 'User') stores them for your user account.
# Then open a new terminal AND restart Claude Code so the governor's shell inherits them.
# Never commit real keys; this file holds placeholders only.
#
# Check what Copilot sees:   copilot help environment
# Smoke test:                copilot -p "Reply with the single word: ready" --no-ask-user
#   (with OpenCode:          pwsh -NoProfile -File .claude/scripts/windows/with-opencode.ps1 copilot -p "Reply with: ready" --no-ask-user)
# Copilot CLI on Windows needs PowerShell 7+ (pwsh); the pipeline's scripts run in it too.

function Set-UserEnv([string]$Name, [string]$Value) { [Environment]::SetEnvironmentVariable($Name, $Value, 'User') }

# ---- Option A: GitHub Copilot subscription (no BYOK) ---------------------------------------------
# Run `copilot` once and type /login. Nothing else to set.
# In pipeline.config: COPILOT_WRAPPER=""
# Set-UserEnv COPILOT_MODEL '<a model your plan offers>'      # optional

# ---- Option B: OpenCode Go / Zen through the bundled proxy ---------------------------------------
# The proxy (.claude/scripts/common/opencode-proxy.mjs, needs Node 18+) adds the headers OpenCode wants
# and sets COPILOT_PROVIDER_BASE_URL for each run itself — do NOT set it.
# In pipeline.config: COPILOT_WRAPPER="with-opencode.ps1"
Set-UserEnv COPILOT_OFFLINE 'true'
Set-UserEnv COPILOT_PROVIDER_TYPE 'openai'
Set-UserEnv COPILOT_MODEL '<model-id>'
Set-UserEnv COPILOT_PROVIDER_MODEL_ID '<model-id>'
Set-UserEnv COPILOT_PROVIDER_WIRE_MODEL '<model-id>'
# Key: prefer a secret store over a plaintext variable. One-time setup with PowerShell SecretManagement:
#   Install-Module Microsoft.PowerShell.SecretManagement, Microsoft.PowerShell.SecretStore -Scope CurrentUser
#   Register-SecretVault -Name LocalStore -ModuleName Microsoft.PowerShell.SecretStore -DefaultVault
#   Set-Secret -Name opencode-api-key -Secret '<your key>'
Set-UserEnv COPILOT_PROVIDER_API_KEY_COMMAND 'pwsh -NoProfile -Command "Get-Secret -Name opencode-api-key -AsPlainText"'
# Set-UserEnv COPILOT_PROVIDER_API_KEY 'sk-...'                 # plaintext alternative
# Set-UserEnv OPENCODE_UPSTREAM 'https://opencode.ai/zen'       # Zen instead of Go

# ---- Option C: any other OpenAI-compatible endpoint (OpenRouter, vLLM, Ollama, Azure, …) --------
# In pipeline.config: COPILOT_WRAPPER=""
# Set-UserEnv COPILOT_OFFLINE 'true'
# Set-UserEnv COPILOT_PROVIDER_BASE_URL 'https://openrouter.ai/api/v1'   # or http://localhost:11434/v1
# Set-UserEnv COPILOT_PROVIDER_TYPE 'openai'                             # openai | azure | anthropic
# Set-UserEnv COPILOT_PROVIDER_API_KEY_COMMAND 'pwsh -NoProfile -Command "Get-Secret -Name provider-key -AsPlainText"'
# Set-UserEnv COPILOT_MODEL '<model id>'

# ---- GitHub CLI (all options) --------------------------------------------------------------------
# The governor opens PRs with `gh`. Run once: gh auth login
