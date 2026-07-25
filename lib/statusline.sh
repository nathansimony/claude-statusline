#!/bin/bash
# Claude Code statusline renderer.
# Invoked by Claude Code on every render; receives a JSON blob on stdin.
# Reads optional Vercel deployment state from /tmp cache files populated
# by the companion vercel-subscriber daemon.

input=$(cat)

parsed=$(echo "$input" | python3 -c "
import sys, json, re
d = json.load(sys.stdin)
cwd = (d.get('workspace') or {}).get('current_dir') or d.get('cwd') or ''
cw = d.get('context_window') or {}
ctx_used = cw.get('used_percentage')
if ctx_used is None:
    rem = cw.get('remaining_percentage')
    if rem is None:
        rem = (d.get('context') or {}).get('percent_remaining')
    if rem is not None:
        ctx_used = 100 - rem
cost = d.get('cost') or {}
rl = d.get('rate_limits') or {}
model = d.get('model') or {}
# 'effort' is omitted entirely by Claude Code for models that don't support it.
effort = (d.get('effort') or {}).get('level')
# Claude Code already suffixes display_name with '(1M context)' on 1M sessions;
# strip it so the size we render below isn't printed twice.
model_name = re.sub(r'\s*\(1M(?: context)?\)\s*$', '', model.get('display_name') or '')
def fmt_size(n):
    if not n: return ''
    for div, unit in ((1000000, 'M'), (1000, 'k')):
        if n >= div:
            v = n / div
            return f'{v:.0f}{unit}' if v == int(v) else f'{v:.1f}{unit}'
    return str(int(n))
def fmt(v, kind='int'):
    if v is None: return ''
    if kind == 'money': return f'{v:.2f}'
    return str(int(v))
print(cwd)
print(fmt(ctx_used))
print(fmt(cost.get('total_cost_usd'), 'money'))
print(fmt(cost.get('total_duration_ms')))
print(fmt((rl.get('five_hour') or {}).get('used_percentage')))
print(fmt((rl.get('seven_day') or {}).get('used_percentage')))
print(fmt(cost.get('total_lines_added')))
print(fmt(cost.get('total_lines_removed')))
print(model_name)
print(effort or '')
print(fmt_size(cw.get('context_window_size')))
")
cwd=$(echo "$parsed"           | sed -n '1p')
ctx_used=$(echo "$parsed"      | sed -n '2p')
cost_usd=$(echo "$parsed"      | sed -n '3p')
dur_ms=$(echo "$parsed"        | sed -n '4p')
limit_5h=$(echo "$parsed"      | sed -n '5p')
limit_7d=$(echo "$parsed"      | sed -n '6p')
lines_added=$(echo "$parsed"   | sed -n '7p')
lines_removed=$(echo "$parsed" | sed -n '8p')
model_name=$(echo "$parsed"    | sed -n '9p')
effort=$(echo "$parsed"        | sed -n '10p')
ctx_size=$(echo "$parsed"      | sed -n '11p')

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

# --- engine: model, context size, effort — e.g. "Opus 5 (1M) ●" ---
# One flat orange for the whole cluster: this is session identity, not a state
# to react to, so it deliberately stays out of the gray/yellow/red grammar.
# Effort renders as a 5-slot dot meter: ●○○○○ low … ●●●●● max.
# Only two glyphs, ● U+25CF and ○ U+25CB, both East Asian Width 'A' and both from
# the same circle family — so every level is the same 5 columns wide and sits on
# the same optical center. Mixed-family ramps (◐◉◈, or the quadrant fills ◔◕)
# can't hold that: those glyphs differ in width class and vertical placement.
# Unknown levels fall back to the bare word so a new level is never swallowed.
# Both the size and the meter drop out when absent from the payload.
engine_str=""
if [ -n "$model_name" ]; then
  engine_str="  \033[38;5;208m${model_name}"
  [ -n "$ctx_size" ] && engine_str="${engine_str} (${ctx_size})"
  case "$effort" in
    low)    engine_str="${engine_str} ●○○○○" ;;
    medium) engine_str="${engine_str} ●●○○○" ;;
    high)   engine_str="${engine_str} ●●●○○" ;;
    xhigh)  engine_str="${engine_str} ●●●●○" ;;
    max)    engine_str="${engine_str} ●●●●●" ;;
    "")     ;;
    *)      engine_str="${engine_str} ${effort}" ;;
  esac
  engine_str="${engine_str}\033[0m"
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

# --- context % used (high = bad, mirrors limits' semantics) ---
ctx_str=""
if [ -n "$ctx_used" ]; then
  if   [ "$ctx_used" -ge 85 ] 2>/dev/null; then ctx_str="  \033[31mcontext ${ctx_used}%\033[0m"
  elif [ "$ctx_used" -ge 70 ] 2>/dev/null; then ctx_str="  \033[33mcontext ${ctx_used}%\033[0m"
  else                                           ctx_str="  \033[90mcontext ${ctx_used}%\033[0m"
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

# --- session diff (+N added green / -N removed red); hidden when both are zero ---
diff_str=""
if [ -n "$lines_added" ] && [ -n "$lines_removed" ] && { [ "$lines_added" -gt 0 ] 2>/dev/null || [ "$lines_removed" -gt 0 ] 2>/dev/null; }; then
  diff_str="  \033[32m+${lines_added}\033[0m \033[31m-${lines_removed}\033[0m"
fi

# --- vercel deployment triangle (optional; read-only from cache) ---
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
      vercel_str="  ${color}▲\033[0m \033[90m${v_url}\033[0m"
    fi
  fi
fi

# Group segments into visual clusters; insert a separator only between
# non-empty clusters so a missing field never leaves a dangling dot.
# Strip one leading space from each cluster so the dot is symmetric (1sp · 1sp).
sep=" \033[90m·\033[0m"
identity="\033[36m/${dir_name}\033[0m${git_str}"
engine="${engine_str}"
capacity="${ctx_str}${limits_str}"
metrics="${cost_str}${dur_str}"
diff="${diff_str}"
deploy="${vercel_str}"

out="$identity"
[ -n "$engine" ]   && out="${out}${sep}${engine# }"
[ -n "$capacity" ] && out="${out}${sep}${capacity# }"
[ -n "$metrics" ]  && out="${out}${sep}${metrics# }"
[ -n "$diff" ]     && out="${out}${sep}${diff# }"
[ -n "$deploy" ]   && out="${out}${sep}${deploy# }"
printf "%b" "$out"
