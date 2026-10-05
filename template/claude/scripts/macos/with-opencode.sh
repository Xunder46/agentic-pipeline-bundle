#!/usr/bin/env bash
# Runs a command (normally `copilot ...`) behind a private OpenCode proxy: one proxy, one
# x-opencode-session, for that one invocation. Points Copilot CLI at the proxy and cleans up after.
#
#   bash .claude/scripts/macos/with-opencode.sh copilot -p "Hello" --no-ask-user
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp="$(mktemp -d)"
export OPENCODE_SESSION="${OPENCODE_SESSION:-copilot-$(date +%Y%m%d-%H%M%S)-$$}"

# Proxy log (one line per request: path, model, status). Kept if OPENCODE_PROXY_LOG is set.
log="${OPENCODE_PROXY_LOG:-$tmp/proxy.log}"
node "$here/../common/opencode-proxy.mjs" > "$tmp/port" 2> "$log" &
proxy=$!
cleanup() { kill "$proxy" 2>/dev/null || true; rm -rf "$tmp"; }
trap cleanup EXIT

for _ in $(seq 1 100); do
  if [[ -s $tmp/port ]]; then break; fi
  sleep 0.1
done
if [[ ! -s $tmp/port ]]; then
  echo "OpenCode proxy failed to start:" >&2
  cat "$log" >&2
  exit 1
fi

export COPILOT_PROVIDER_BASE_URL="http://127.0.0.1:$(head -n 1 "$tmp/port")/v1"
"$@"
