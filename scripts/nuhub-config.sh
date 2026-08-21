#!/bin/bash
# scripts/nuhub-config.sh — derive .mcp.json from this machine's nuhub SSOT.
#
# The nuhub URL/port lives in exactly ONE place per machine: ~/.nuhandoff/hub.toml
# (the same file the auth helper already reads). .mcp.json is generated from it,
# never hand-edited — so a port move is one edit in one file and the client can't
# drift out of sync with the server (the 8000→8011 class of bug).
#
#   scripts/nuhub-config.sh            # (re)generate .mcp.json from hub.toml
#   scripts/nuhub-config.sh --check    # verify they agree; nonzero + message on drift
#
# Override the SSOT dir with NUHANDOFF_DIR (defaults to ~/.nuhandoff).

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NUHANDOFF_DIR="${NUHANDOFF_DIR:-$HOME/.nuhandoff}"
HUB_TOML="$NUHANDOFF_DIR/hub.toml"
HELPER="$NUHANDOFF_DIR/auth-header.sh"
MCP_JSON="$ROOT/.mcp.json"

toml_value() { sed -n "s/^$1[[:space:]]*=[[:space:]]*\"\(.*\)\"\$/\1/p" "$HUB_TOML" 2>/dev/null | head -1; }
json_url()   { grep -oE '"url"[[:space:]]*:[[:space:]]*"[^"]*"' "$MCP_JSON" 2>/dev/null | sed -E 's/.*"([^"]*)"$/\1/' | head -1; }

[ -f "$HUB_TOML" ] || { echo "nuhub: $HUB_TOML not found — cannot resolve the nuhub URL on this machine." >&2; exit 2; }
URL="$(toml_value url)"
[ -n "$URL" ] || { echo "nuhub: no 'url' in $HUB_TOML — add e.g. url = \"http://<tower-tailnet>:8011/mcp\"." >&2; exit 2; }

render() {
  printf '{\n  "mcpServers": {\n    "nuhub": {\n      "type": "http",\n      "url": "%s",\n      "headersHelper": "%s"\n    }\n  }\n}\n' "$URL" "$HELPER"
}

case "${1:-write}" in
  --check)
    have="$(json_url)"
    if [ "$have" != "$URL" ]; then
      echo "⚠️  nuhub config drift: .mcp.json url is '${have:-<none>}' but $HUB_TOML says '$URL'." >&2
      echo "    Fix: scripts/nuhub-config.sh && restart the session (.mcp.json is read at startup)." >&2
      exit 1
    fi
    ;;
  write|"")
    render > "$MCP_JSON"
    echo "nuhub: wrote $MCP_JSON (url=$URL)"
    ;;
  *) echo "usage: nuhub-config.sh [--check]" >&2; exit 64 ;;
esac
