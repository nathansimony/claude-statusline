# claude-statusline

A custom statusline for [Claude Code](https://claude.com/claude-code): rate-limit usage, context window, session cost & duration, lines added/removed, and an optional live Vercel deployment indicator. Visual clusters separated by dim dots.

```
/my-project  feature-branch* · context 28%  limits 38%/12% · $0.85  12m · +127 -34 · ▲ my-project.vercel.app
```

## Features

- **Path + branch** — cyan `/dir` and green branch name; branch turns yellow with a `*` when there are uncommitted changes
- **Context window %** — % used (number rises as context fills). Turns yellow at ≥70%, red at ≥85%
- **Plan rate limits** — `limits 5h%/7d%` from Claude Code's gateway, color-coded by the higher of the two (gray <50%, yellow <80%, red ≥80%)
- **Session cost** — theoretical API price for the current session
- **Session duration** — wall-clock time the assistant has been working
- **Session diff** — `+N -N` lines added (green) / removed (red); auto-hides on a fresh session
- **Cluster separators** — dim `·` dots group segments into identity / capacity / metrics / diff / deployment; separators only appear between clusters that have content
- **Vercel deployment triangle** *(optional)* — `▲` colored by the latest deployment state for the current branch: yellow=BUILDING, green=READY, red=ERROR. Updated in near-real-time via webhook → ntfy.sh → local subscriber, with bounded polling to fill the gap left by `deployment.ready` requiring an integration.

## Requirements

- macOS (Intel or Apple Silicon). Linux/Windows ports welcome via PR.
- Claude Code CLI
- `python3` on `$PATH` (ships with recent macOS)
- For the optional Vercel dot:
  - [Vercel CLI](https://vercel.com/docs/cli) (`npm i -g vercel`)
  - A Vercel account with at least one linked project

## Install

```bash
git clone https://github.com/nathansimony/claude-statusline.git
cd claude-statusline
./install.sh
```

The installer:
1. Copies `lib/statusline.sh` → `~/.claude/statusline.sh`
2. Adds a `statusLine` block to `~/.claude/settings.json` (existing file is backed up to `.bak`)
3. Asks whether to set up the Vercel dot. If yes:
   - Generates a random ntfy.sh topic (acts as a shared secret)
   - Creates a Vercel webhook subscribed to `deployment.created`, `deployment.canceled`, `deployment.error`
   - Installs a launchd agent that streams events from ntfy.sh and writes deployment state to `/tmp` cache files

Restart Claude Code (or run `/config`) after installing to pick up the new statusline.

## Uninstall

From the cloned repo:

```bash
./uninstall.sh
```

This removes the scripts, unloads the launchd agent, and strips the `statusLine` block from `settings.json`. The Vercel webhook on your account is **not** auto-removed — see the uninstall output for the manual command.

## How the Vercel dot works

```
Vercel webhook (deployment.created / canceled / error)
  → POST https://ntfy.sh/<your-topic>
  → ~/.claude/vercel-subscriber.sh (long-lived curl -sN stream)
  → /tmp/claude-statusline-vercel-<sha1(projectId-branch)>
  → ~/.claude/statusline.sh reads cache on render
```

When a `deployment.created` event arrives, the subscriber writes `BUILDING` to the cache and spawns a bounded poll loop that polls the Vercel API every 5s until the deployment reaches a terminal state (READY/ERROR/CANCELED), then exits. Net result: ~6 API calls per deployment, zero idle polling.

**Trade-offs:**
- ntfy.sh is a free public pub/sub service. Your topic name is the only thing keeping the events private — the installer generates 128 bits of randomness for it, so it's effectively unguessable, but you can rotate it by deleting `~/.claude/vercel-webhook-topic` and re-running the installer.
- The bounded poll uses your Vercel auth token. If it expires, BUILDING → READY transitions stop working (BUILDING/ERROR/CANCELED still fire via push). Run `vercel login` again to fix.

## Customizing

Open `~/.claude/statusline.sh` and edit. Common changes:

| Change | Where |
|---|---|
| Color thresholds | `if [ "$ctx_used" -ge 85 ]` / `if [ "$hi" -ge 80 ]` (context uses ≥, lower = healthier) |
| Cluster grouping | The bottom of the script: `identity`, `capacity`, `metrics`, `diff`, `deploy` variables — move a `$..._str` into a different cluster, or add/remove a cluster line |
| Separator character | The `sep=` line near the bottom: change `·` to `│`, `▸`, `—`, etc. |
| Drop a segment | Comment out its block; it falls out of its cluster automatically (empty clusters get no separator) |
| Add a field | Extract from the JSON blob inside the top `python3 -c` block, add a new `${...}_str` segment, drop it into a cluster |

The full JSON Claude Code pipes in includes more fields than we use: `session_id`, `session_name`, `model`, `effort`, `output_style`, `cost.total_api_duration_ms`, `context_window.total_input_tokens`, etc. Dump a sample by adding this at the top of the script:

```bash
echo "$input" > /tmp/last-input.json
```

then inspect with `python3 -m json.tool < /tmp/last-input.json`.

## Troubleshooting

| Symptom | Check |
|---|---|
| No statusline at all | `cat ~/.claude/settings.json` — does it have a `statusLine` block? |
| Garbled escape codes | Your terminal might not handle ANSI (or OSC 8). This script avoids OSC 8 deliberately. |
| Vercel dot never appears | `cat /tmp/claude-vercel-subscriber.log` — daemon running? Webhook firing? Topic correct? |
| Dot stuck on BUILDING | Vercel auth token expired. Run `vercel login`. |
| `limits` segment missing | You're on an older Claude Code version that doesn't expose `rate_limits`. Upgrade. |

## License

MIT — see [LICENSE](LICENSE).
