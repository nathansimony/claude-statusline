#!/bin/bash
# Claude Code statusline renderer.
# Invoked by Claude Code on every render; receives a JSON blob on stdin.
# Reads optional Vercel deployment state from /tmp cache files populated
# by the companion vercel-subscriber daemon.

input=$(cat)

parsed=$(echo "$input" | python3 -c "
import sys, json
d = json.load(sys.stdin)
cwd = (d.get('workspace') or {}).get('current_dir') or d.get('cwd') or ''
cw = d.get('context_window') or {}
ctx_left = cw.get('remaining_percentage')
if ctx_left is None:
    ctx_left = (d.get('context') or {}).get('percent_remaining')
cost = d.get('cost') or {}
rl = d.get('rate_limits') or {}
def fmt(v, kind='int'):
    if v is None: return ''
    if kind == 'money': return f'{v:.2f}'
    return str(int(v))
print(cwd)
print(fmt(ctx_left))
print(fmt(cost.get('total_cost_usd'), 'money'))
print(fmt(cost.get('total_duration_ms')))
print(fmt((rl.get('five_hour') or {}).get('used_percentage')))
print(fmt((rl.get('seven_day') or {}).get('used_percentage')))
")
cwd=$(echo "$parsed"      | sed -n '1p')
ctx_left=$(echo "$parsed" | sed -n '2p')
cost_usd=$(echo "$parsed" | sed -n '3p')
dur_ms=$(echo "$parsed"   | sed -n '4p')
limit_5h=$(echo "$parsed" | sed -n '5p')
limit_7d=$(echo "$parsed" | sed -n '6p')

# --- dir ---
short_cwd="${cwd/#$HOME/~}"
dir_name=$(basename "$short_cwd")
[ "$short_cwd" = "~" ] && dir_name="~"

# --- git ---
git_str=""
branch=""
if [ -n "$cwd" ] && git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  branch=$(git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null || git -C "$cwd" rev-parse --short HEAD 2>/dev/null)
  if [ -n "$branch" ]; then
    if ! git -C "$cwd" diff --quiet 2>/dev/null || ! git -C "$cwd" diff --cached --quiet 2>/dev/null; then
      git_str="  \033[33m${branch}*\033[0m"
    else
      git_str="  \033[32m${branch}\033[0m"
    fi
  fi
fi

# --- cost ---
cost_str=""
[ -n "$cost_usd" ] && cost_str="  \033[90m\$${cost_usd}\033[0m"

# --- duration ---
dur_str=""
if [ -n "$dur_ms" ] && [ "$dur_ms" -gt 0 ] 2>/dev/null; then
  total_s=$(( dur_ms / 1000 ))
  if   [ "$total_s" -lt 60 ];   then dur_fmt="${total_s}s"
  elif [ "$total_s" -lt 3600 ]; then dur_fmt="$(( total_s / 60 ))m"
  else                                dur_fmt="$(( total_s / 3600 ))h$(( (total_s % 3600) / 60 ))m"
  fi
  dur_str="  \033[90m${dur_fmt}\033[0m"
fi

# --- context % (remaining; red <15, yellow <30, else gray) ---
ctx_str=""
if [ -n "$ctx_left" ]; then
  if   [ "$ctx_left" -lt 15 ] 2>/dev/null; then ctx_str="  \033[31mcontext ${ctx_left}%\033[0m"
  elif [ "$ctx_left" -lt 30 ] 2>/dev/null; then ctx_str="  \033[33mcontext ${ctx_left}%\033[0m"
  else                                           ctx_str="  \033[90mcontext ${ctx_left}%\033[0m"
  fi
fi

# --- rate limits (used %; gray <50, yellow <80, red >=80) ---
limits_str=""
if [ -n "$limit_5h" ] || [ -n "$limit_7d" ]; then
  hi=0
  [ -n "$limit_5h" ] && [ "$limit_5h" -gt "$hi" ] 2>/dev/null && hi=$limit_5h
  [ -n "$limit_7d" ] && [ "$limit_7d" -gt "$hi" ] 2>/dev/null && hi=$limit_7d
  if   [ "$hi" -ge 80 ]; then lcolor="\033[31m"
  elif [ "$hi" -ge 50 ]; then lcolor="\033[33m"
  else                         lcolor="\033[90m"
  fi
  limits_str="  ${lcolor}limits ${limit_5h:-?}%/${limit_7d:-?}%\033[0m"
fi

# --- vercel deployment dot (optional; read-only from cache) ---
vercel_str=""
project_id=""
if [ -f "$cwd/.vercel/project.json" ]; then
  project_id=$(python3 -c "
import json
try: print(json.load(open('$cwd/.vercel/project.json')).get('projectId',''))
except Exception: pass
" 2>/dev/null)
elif [ -f "$cwd/.vercel/repo.json" ]; then
  project_id=$(python3 -c "
import json
try:
    d = json.load(open('$cwd/.vercel/repo.json'))
    projects = d.get('projects', [])
    if projects: print(projects[0].get('id',''))
except Exception: pass
" 2>/dev/null)
fi

if [ -n "$branch" ] && [ -n "$project_id" ]; then
  cache_key=$(printf "%s-%s" "$project_id" "$branch" | shasum 2>/dev/null | cut -d' ' -f1)
  cache_file="/tmp/claude-statusline-vercel-$cache_key"
  if [ -f "$cache_file" ]; then
    v_url=$(sed -n '1p' "$cache_file" 2>/dev/null)
    v_state=$(sed -n '2p' "$cache_file" 2>/dev/null)
    if [ -n "$v_url" ]; then
      case "$v_state" in
        READY)                          color="\033[32m" ;;
        BUILDING|QUEUED|INITIALIZING)   color="\033[33m" ;;
        ERROR|CANCELED)                 color="\033[31m" ;;
        *)                              color="\033[90m" ;;
      esac
      vercel_str="  ${color}●\033[0m \033[90m${v_url}\033[0m"
    fi
  fi
fi

printf "\033[36m%s\033[0m%b%b%b%b%b%b" \
  "$dir_name" "$git_str" "$ctx_str" "$limits_str" "$cost_str" "$dur_str" "$vercel_str"
