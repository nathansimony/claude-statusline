#!/usr/bin/env bash
# claude-statusline uninstaller.

set -euo pipefail

CLAUDE_DIR="$HOME/.claude"
LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
PLIST_PATH="$LAUNCH_AGENTS/com.${USER}.claude-statusline.vercel-subscriber.plist"
SETTINGS="$CLAUDE_DIR/settings.json"

echo "→ Unloading + removing launchd job (if installed)"
if [ -f "$PLIST_PATH" ]; then
  launchctl unload "$PLIST_PATH" 2>/dev/null || true
  rm -f "$PLIST_PATH"
fi

echo "→ Removing installed scripts"
rm -f "$CLAUDE_DIR/statusline.sh" \
      "$CLAUDE_DIR/vercel-subscriber.sh" \
      "$CLAUDE_DIR/vercel-webhook-topic"

if [ -f "$SETTINGS" ]; then
  echo "→ Removing statusLine entry from $SETTINGS (backup at $SETTINGS.bak)"
  cp "$SETTINGS" "$SETTINGS.bak"
  python3 - <<EOF
import json, pathlib
p = pathlib.Path("$SETTINGS")
s = json.loads(p.read_text())
s.pop("statusLine", None)
p.write_text(json.dumps(s, indent=2) + "\n")
EOF
fi

echo "→ Clearing cached deployment state in /tmp"
rm -f /tmp/claude-statusline-vercel-* /tmp/claude-vercel-subscriber.log

cat <<'EOF'

✓ Uninstalled.

Notes:
  - The Vercel webhook on your account was NOT removed (it'd just POST to a topic no one is listening to).
    To delete it: vercel webhooks ls --scope <your-team>
                  vercel webhooks remove <id> --scope <your-team>
  - Restart Claude Code to drop the now-orphaned statusLine reference.

EOF
