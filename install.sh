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

# --- theme: reconcile an "auto" setting with the actual terminal --------------
# The statusline reads the `theme` key to pick its palette. Claude Code resolves
# `auto` by querying the terminal over OSC 11 and holding the answer in memory,
# where the statusline cannot reach it — so under `auto` the statusline falls
# back to dark, and a light terminal ends up with a dark statusline.
#
# The installer runs in a plain interactive shell with no TUI holding the tty,
# so it is the one place the query is safe. We use it to offer an explicit theme
# rather than to cache a value: settings.json stays the single source of truth,
# so nothing can go stale or disagree later.

CURRENT_THEME=$(python3 -c "
import json
try: print((json.load(open('$SETTINGS')) or {}).get('theme') or 'auto')
except Exception: print('auto')
" 2>/dev/null)

if [ "$CURRENT_THEME" = "auto" ] && [ -t 0 ] && [ -t 1 ]; then
  DETECTED=$(python3 - <<'PY' 2>/dev/null
import os, re, select, termios, tty
try:
    fd = os.open('/dev/tty', os.O_RDWR | os.O_NOCTTY)
except OSError:
    raise SystemExit
saved = None
try:
    if not os.isatty(fd): raise SystemExit
    saved = termios.tcgetattr(fd); tty.setraw(fd)
    os.write(fd, b'\033]11;?\033\\')
    buf = b''
    while len(buf) < 64:
        if not select.select([fd], [], [], 0.25)[0]: break
        c = os.read(fd, 32)
        if not c: break
        buf += c
        if b'\007' in buf or b'\033\\' in buf[2:]: break
    m = re.search(r'rgba?:([0-9a-fA-F]{1,4})/([0-9a-fA-F]{1,4})/([0-9a-fA-F]{1,4})',
                  buf.decode('ascii', 'ignore'))
    if m:
        r, g, b = (int(h, 16) / (16 ** len(h) - 1) for h in m.groups())
        # Same relative-luminance test Claude Code applies to the OSC 11 reply.
        print('light' if (0.2126*r + 0.7152*g + 0.0722*b) > 0.5 else 'dark')
finally:
    if saved is not None:
        try: termios.tcsetattr(fd, termios.TCSADRAIN, saved)
        except Exception: pass
    os.close(fd)
PY
)
  # Only speak up when the fallback would actually be wrong.
  if [ "$DETECTED" = "light" ]; then
    echo
    echo "Your Claude Code theme is 'auto' and this terminal has a light background."
    echo "The statusline cannot see how Claude Code resolved 'auto', so it defaults to"
    echo "dark — which would put dark colours on your light terminal."
    read -r -p "Set theme to \"light\" in settings.json to keep them in step? [y/N] " tyn
    if [[ "$tyn" =~ ^[Yy]$ ]]; then
      python3 - <<EOF
import json, pathlib
p = pathlib.Path("$SETTINGS")
s = json.loads(p.read_text()); s["theme"] = "light"
p.write_text(json.dumps(s, indent=2) + "\n")
EOF
      echo "→ theme set to \"light\". Change it any time with /theme."
    else
      echo "→ Left as 'auto'. Pick \"Light mode\" in /theme if the colours look off."
    fi
  fi
fi

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
