#!/usr/bin/env bash
# claude-statusline installer (macOS only).
# Installs the render script, registers it in ~/.claude/settings.json,
# and optionally sets up the Vercel deployment dot.

set -euo pipefail

# --- preflight ---------------------------------------------------------------

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This installer supports macOS only. PRs welcome for Linux/Windows."
  exit 1
fi
if ! command -v python3 >/dev/null; then
  echo "python3 is required but not found on PATH."
  exit 1
fi

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$HOME/.claude"
LAUNCH_AGENTS="$HOME/Library/LaunchAgents"

mkdir -p "$CLAUDE_DIR" "$LAUNCH_AGENTS"

# --- core: render script + settings.json -------------------------------------

echo "→ Installing render script to $CLAUDE_DIR/statusline.sh"
install -m 0755 "$REPO_DIR/lib/statusline.sh" "$CLAUDE_DIR/statusline.sh"

SETTINGS="$CLAUDE_DIR/settings.json"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
echo "→ Registering statusLine in $SETTINGS (backup at $SETTINGS.bak)"
cp "$SETTINGS" "$SETTINGS.bak"
python3 - <<EOF
import json, pathlib
p = pathlib.Path("$SETTINGS")
s = json.loads(p.read_text())
s["statusLine"] = {"type": "command", "command": "$CLAUDE_DIR/statusline.sh"}
p.write_text(json.dumps(s, indent=2) + "\n")
EOF

# --- optional: Vercel deployment dot -----------------------------------------

echo
read -r -p "Set up the Vercel deployment dot? Needs the vercel CLI + an account. [y/N] " yn
if [[ "$yn" =~ ^[Yy]$ ]]; then
  if ! command -v vercel >/dev/null; then
    echo "  vercel CLI not found. Install with: npm i -g vercel"
    echo "  Then re-run this installer."
    exit 1
  fi
  if ! vercel whoami >/dev/null 2>&1; then
    echo "→ Running 'vercel login'..."
    vercel login
  fi

  TOPIC="claude-vercel-$(openssl rand -hex 16)"
  echo "$TOPIC" > "$CLAUDE_DIR/vercel-webhook-topic"
  chmod 600 "$CLAUDE_DIR/vercel-webhook-topic"
  echo "→ Generated ntfy topic (treat as secret): $TOPIC"

  echo
  echo "Available Vercel scopes (teams):"
  vercel teams ls 2>&1 || true
  echo
  read -r -p "Vercel team slug to attach the webhook to (blank = personal account): " SCOPE
  SCOPE_ARGS=()
  [ -n "$SCOPE" ] && SCOPE_ARGS=(--scope "$SCOPE")

  echo "→ Creating Vercel webhook..."
  vercel webhooks create "https://ntfy.sh/$TOPIC" \
    --event deployment.created \
    --event deployment.canceled \
    --event deployment.error \
    "${SCOPE_ARGS[@]}"

  echo "→ Installing subscriber to $CLAUDE_DIR/vercel-subscriber.sh"
  install -m 0755 "$REPO_DIR/lib/vercel-subscriber.sh" "$CLAUDE_DIR/vercel-subscriber.sh"

  PLIST_PATH="$LAUNCH_AGENTS/com.${USER}.claude-statusline.vercel-subscriber.plist"
  echo "→ Generating launchd plist at $PLIST_PATH"
  sed -e "s|__HOME__|$HOME|g" -e "s|__USER__|$USER|g" \
    "$REPO_DIR/templates/launchd.plist.tmpl" > "$PLIST_PATH"

  # If already loaded (re-install), unload first
  launchctl unload "$PLIST_PATH" 2>/dev/null || true
  launchctl load "$PLIST_PATH"
  echo "→ Subscriber daemon loaded."
fi

# --- done --------------------------------------------------------------------

cat <<'EOF'

✓ Installed.

Next:
  - Restart Claude Code (or run /config) to see the new statusline.
  - Logs:    tail -f /tmp/claude-vercel-subscriber.log
  - Cache:   ls /tmp/claude-statusline-vercel-*
  - Manage:  launchctl {load,unload} ~/Library/LaunchAgents/com.$USER.claude-statusline.vercel-subscriber.plist
  - Uninstall: ./uninstall.sh

EOF
