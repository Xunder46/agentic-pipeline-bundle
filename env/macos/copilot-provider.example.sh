# Copilot CLI model provider — shell environment. Pick ONE option, copy its lines into your shell
# profile (~/.zshrc or ~/.bash_profile), then open a new terminal AND restart Claude Code so the
# governor's shell inherits them. Never commit real keys; this file holds placeholders only.
#
# Check what Copilot sees:   copilot help environment
# Smoke test:                copilot -p "Reply with the single word: ready" --no-ask-user
#   (with OpenCode:          bash .claude/scripts/macos/with-opencode.sh copilot -p "Reply with: ready" --no-ask-user)

# ---- Option A: GitHub Copilot subscription (no BYOK) ---------------------------------------------
# Run `copilot` once and type /login (or export a token). Nothing else to set.
# In pipeline.config: COPILOT_WRAPPER=""
# export COPILOT_GITHUB_TOKEN="github_pat_..."        # optional: token instead of /login
# export COPILOT_MODEL="<a model your plan offers>"    # optional

# ---- Option B: OpenCode Go / Zen through the bundled proxy ---------------------------------------
# The proxy (.claude/scripts/common/opencode-proxy.mjs, needs Node 18+) adds the session and user-agent
# headers OpenCode wants and sets COPILOT_PROVIDER_BASE_URL for each run itself — do NOT export it.
# In pipeline.config: COPILOT_WRAPPER="with-opencode.sh"
export COPILOT_OFFLINE=true                            # no GitHub login, telemetry or auto-update
export COPILOT_PROVIDER_TYPE=openai                    # OpenCode speaks the OpenAI-compatible API
export COPILOT_MODEL="<model-id>"              # the model id exactly as your plan lists it
export COPILOT_PROVIDER_MODEL_ID="<model-id>"  # well-known id: token limits, agent config
export COPILOT_PROVIDER_WIRE_MODEL="<model-id>" # the name sent on the wire
# Key: prefer a keychain lookup over a plaintext export (macOS example; store it once with
#   security add-generic-password -a "$USER" -s opencode-api-key -w '<your key>'  ).
export COPILOT_PROVIDER_API_KEY_COMMAND='security find-generic-password -a "$USER" -s opencode-api-key -w'
# export COPILOT_PROVIDER_API_KEY="sk-..."            # plaintext alternative
# export OPENCODE_UPSTREAM="https://opencode.ai/zen"  # Zen instead of Go (default: .../zen/go)

# ---- Option C: any other OpenAI-compatible endpoint (OpenRouter, vLLM, Ollama, Azure, …) --------
# In pipeline.config: COPILOT_WRAPPER=""
# export COPILOT_OFFLINE=true
# export COPILOT_PROVIDER_BASE_URL="https://openrouter.ai/api/v1"   # or http://localhost:11434/v1
# export COPILOT_PROVIDER_TYPE=openai                              # openai | azure | anthropic
# export COPILOT_PROVIDER_API_KEY_COMMAND='security find-generic-password -a "$USER" -s provider-key -w'
# export COPILOT_MODEL="<model id>"
# export COPILOT_PROVIDER_HEADERS=$'X-Title: my-pipeline'         # extra headers, if the provider wants any
# export COPILOT_PROVIDER_WIRE_API=responses                       # only for GPT-5-series models

# ---- GitHub CLI (all options) --------------------------------------------------------------------
# The governor opens PRs with `gh`. Run once: gh auth login
