#!/bin/bash
# Subscribes to ntfy.sh for Vercel webhook events and writes deployment
# state to /tmp cache files consumed by the statusline render script.
#
# On deployment.created, spawns a bounded poll loop that hits the Vercel
# API every 5s until the deployment reaches a terminal state (READY/
# ERROR/CANCELED). This compensates for the fact that `deployment.ready`
# events require an integration with registered checks, which plain
# account webhooks don't have access to.
#
# Cache key: sha1("<projectId>-<branch>") — must match what the
# statusline render script computes.

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

TOPIC_FILE="$HOME/.claude/vercel-webhook-topic"
TOKEN_FILE="$HOME/Library/Application Support/com.vercel.cli/auth.json"
CACHE_DIR="/tmp"
LOG_FILE="/tmp/claude-vercel-subscriber.log"

[ -f "$TOPIC_FILE" ] || { echo "no topic file at $TOPIC_FILE" >&2; exit 1; }
TOPIC=$(cat "$TOPIC_FILE")

log()       { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }
get_token() { python3 -c "import json; print(json.load(open('$TOKEN_FILE'))['token'])" 2>/dev/null; }

write_cache() {
  local projectId="$1" branch="$2" url="$3" state="$4"
  local key
  key=$(printf "%s-%s" "$projectId" "$branch" | shasum | cut -d' ' -f1)
  local file="$CACHE_DIR/claude-statusline-vercel-$key"
  printf "%s\n%s\n" "$url" "$state" > "$file.tmp" && mv "$file.tmp" "$file"
  log "  cache write key=$key state=$state url=$url"
}

poll_deployment() {
  local depId="$1" projectId="$2" branch="$3" teamId="$4"
  local token; token=$(get_token)
  [ -z "$token" ] && { log "  poll skipped: no vercel token"; return; }
  log "  poll start dep=$depId"
  for i in $(seq 1 60); do
    sleep 5
    resp=$(curl -s "https://api.vercel.com/v13/deployments/$depId?teamId=$teamId" -H "Authorization: Bearer $token")
    parsed=$(echo "$resp" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    aliases = d.get('alias') or []
    print(aliases[0] if aliases else d.get('url',''))
    print(d.get('readyState') or d.get('state') or '')
except Exception: pass
")
    state=$(echo "$parsed" | sed -n '2p')
    url=$(echo "$parsed"   | sed -n '1p')
    [ -z "$state" ] && continue
    write_cache "$projectId" "$branch" "$url" "$state"
    log "  poll i=$i state=$state"
    case "$state" in
      READY|ERROR|CANCELED) log "  poll done terminal=$state"; return ;;
    esac
  done
  log "  poll timeout dep=$depId"
}

log "subscriber started (topic=$TOPIC, pid=$$)"

while true; do
  curl -sN --max-time 0 "https://ntfy.sh/$TOPIC/json" 2>/dev/null | while IFS= read -r line; do
    [ -z "$line" ] && continue

    parsed=$(echo "$line" | python3 -c "
import sys, json
try:
    msg = json.loads(sys.stdin.read())
    if msg.get('event') != 'message': sys.exit()
    payload = json.loads(msg.get('message','{}'))
    evt = payload.get('type','')
    p   = payload.get('payload', {})
    dep = p.get('deployment', {}) or {}
    proj = p.get('project', {}) or {}
    team = p.get('team', {}) or {}
    meta = dep.get('meta', {}) or {}
    branch = meta.get('githubCommitRef') or meta.get('gitBranch') or ''
    state_map = {
        'deployment.created':  'BUILDING',
        'deployment.canceled': 'CANCELED',
        'deployment.error':    'ERROR',
    }
    print(evt)
    print(state_map.get(evt, ''))
    print(proj.get('id',''))
    print(branch)
    print(dep.get('url',''))
    print(dep.get('id',''))
    print(team.get('id',''))
except Exception: pass
")
    evt=$(echo       "$parsed" | sed -n '1p')
    state=$(echo     "$parsed" | sed -n '2p')
    projectId=$(echo "$parsed" | sed -n '3p')
    branch=$(echo    "$parsed" | sed -n '4p')
    url=$(echo       "$parsed" | sed -n '5p')
    depId=$(echo     "$parsed" | sed -n '6p')
    teamId=$(echo    "$parsed" | sed -n '7p')

    if [ -n "$state" ] && [ -n "$projectId" ] && [ -n "$branch" ]; then
      log "event $evt branch=$branch state=$state projectId=$projectId"
      write_cache "$projectId" "$branch" "$url" "$state"
      if [ "$evt" = "deployment.created" ] && [ -n "$depId" ]; then
        ( poll_deployment "$depId" "$projectId" "$branch" "$teamId" ) &
      fi
    fi
  done
  log "ntfy stream ended, reconnecting in 2s"
  sleep 2
done
