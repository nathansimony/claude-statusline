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
def fmt_tokens(n):
    # Rounded harder than fmt_size: this figure moves every turn, and a
    # trailing decimal at k scale is churn rather than information.
    if not n: return ''
    if n >= 1000000:
        v = n / 1000000
        return f'{v:.0f}M' if abs(v - round(v)) < 0.05 else f'{v:.1f}M'
    if n >= 1000: return f'{n / 1000:.0f}k'
    return str(int(n))
# Same numerator Claude Code divides to get used_percentage, so the ratio
# shown is exactly the one the color thresholds key off.
ctx_tokens = cw.get('total_input_tokens')
if not ctx_tokens and ctx_used is not None and cw.get('context_window_size'):
    ctx_tokens = round(ctx_used * cw['context_window_size'] / 100)
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
print(fmt_tokens(ctx_tokens))
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
ctx_tokens=$(echo "$parsed"    | sed -n '12p')

# --- palette ---------------------------------------------------------------
# Claude Code's own dark-theme tokens, lifted from the CLI's internal theme
# table so the statusline paints itself the same colors the TUI above it does.
# Truecolor (24-bit) and hardcoded on purpose: these no longer follow your
# terminal theme, which is the point — they follow Claude Code's instead.
# For the light theme, swap in the values commented at the right.
c_claude="\033[38;2;215;119;87m"    # claude    #D77757  (light: 215,119,87)
c_success="\033[38;2;78;186;101m"   # success   #4EBA65  (light:  44,122,57)
c_error="\033[38;2;255;107;128m"    # error     #FF6B80  (light: 171, 43,63)
c_warning="\033[38;2;255;193;7m"    # warning   #FFC107  (light: 150,108,30)
c_inactive="\033[38;2;153;153;153m" # inactive  #999999  (light: 102,102,102)
c_border="\033[38;2;136;136;136m"   # promptBorder #888888  (light: 153,153,153)
c_plan="\033[38;2;72;150;140m"      # planMode  #48968C  (light:   0,102,102)
c_off="\033[0m"

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
      git_str="  ${c_warning}${branch}*${c_off}"
    else
      git_str="  ${c_success}${branch}${c_off}"
    fi
  fi
fi

# --- engine: model + effort — e.g. "Opus 5 (xhigh)" ---
# Flat `claude` orange for the whole cluster: this is session identity, not a
# state to react to, so it stays out of the inactive/warning/error grammar.
# The window size lives in the context segment below, alongside the figure it
# divides into.
engine_str=""
if [ -n "$model_name" ]; then
  engine_str="  ${c_claude}${model_name}"
  [ -n "$effort" ] && engine_str="${engine_str} (${effort})"
  engine_str="${engine_str}${c_off}"
fi

# --- cost ---
cost_str=""
[ -n "$cost_usd" ] && cost_str="  ${c_inactive}\$${cost_usd}${c_off}"

# --- duration ---
dur_str=""
if [ -n "$dur_ms" ] && [ "$dur_ms" -gt 0 ] 2>/dev/null; then
  total_s=$(( dur_ms / 1000 ))
  if   [ "$total_s" -lt 60 ];   then dur_fmt="${total_s}s"
  elif [ "$total_s" -lt 3600 ]; then dur_fmt="$(( total_s / 60 ))m"
  else                                dur_fmt="$(( total_s / 3600 ))h$(( (total_s % 3600) / 60 ))m"
  fi
  dur_str="  ${c_inactive}${dur_fmt}${c_off}"
fi

# --- context % used (high = bad, mirrors limits' semantics) ---
ctx_str=""
if [ -n "$ctx_used" ]; then
  # Prefer absolute used/total ("280k/1M") — it carries the burn as well as the
  # fraction. Falls back to the bare % when either figure is missing.
  if [ -n "$ctx_tokens" ] && [ -n "$ctx_size" ]; then
    ctx_label="context ${ctx_tokens}/${ctx_size}"
  else
    ctx_label="context ${ctx_used}%"
  fi
  if   [ "$ctx_used" -ge 85 ] 2>/dev/null; then ctx_str="  ${c_error}${ctx_label}${c_off}"
  elif [ "$ctx_used" -ge 70 ] 2>/dev/null; then ctx_str="  ${c_warning}${ctx_label}${c_off}"
  else                                           ctx_str="  ${c_inactive}${ctx_label}${c_off}"
  fi
fi

# --- rate limits (used %; gray <50, yellow <80, red >=80) ---
limits_str=""
if [ -n "$limit_5h" ] || [ -n "$limit_7d" ]; then
  hi=0
  [ -n "$limit_5h" ] && [ "$limit_5h" -gt "$hi" ] 2>/dev/null && hi=$limit_5h
  [ -n "$limit_7d" ] && [ "$limit_7d" -gt "$hi" ] 2>/dev/null && hi=$limit_7d
  if   [ "$hi" -ge 80 ]; then lcolor="$c_error"
  elif [ "$hi" -ge 50 ]; then lcolor="$c_warning"
  else                         lcolor="$c_inactive"
  fi
  limits_str="  ${lcolor}limits ${limit_5h:-?}%/${limit_7d:-?}%${c_off}"
fi

# --- session diff (+N added green / -N removed red); hidden when both are zero ---
diff_str=""
if [ -n "$lines_added" ] && [ -n "$lines_removed" ] && { [ "$lines_added" -gt 0 ] 2>/dev/null || [ "$lines_removed" -gt 0 ] 2>/dev/null; }; then
  diff_str="  ${c_success}+${lines_added}${c_off} ${c_error}-${lines_removed}${c_off}"
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
        READY)                          color="$c_success"  ;;
        BUILDING|QUEUED|INITIALIZING)   color="$c_warning"  ;;
        ERROR|CANCELED)                 color="$c_error"    ;;
        *)                              color="$c_inactive" ;;
      esac
      vercel_str="  ${color}▲${c_off} ${c_inactive}${v_url}${c_off}"
    fi
  fi
fi

# Group segments into visual clusters; insert a separator only between
# non-empty clusters so a missing field never leaves a dangling dot.
# Strip one leading space from each cluster so the dot is symmetric (1sp · 1sp).
sep=" ${c_border}·${c_off}"
identity="${c_plan}/${dir_name}${c_off}${git_str}"
engine="${engine_str}"
context="${ctx_str}"
limits="${limits_str}"
metrics="${cost_str}${dur_str}"
diff="${diff_str}"
deploy="${vercel_str}"

out="$identity"
[ -n "$engine" ]   && out="${out}${sep}${engine# }"
[ -n "$context" ]  && out="${out}${sep}${context# }"
[ -n "$limits" ]   && out="${out}${sep}${limits# }"
[ -n "$metrics" ]  && out="${out}${sep}${metrics# }"
[ -n "$diff" ]     && out="${out}${sep}${diff# }"
[ -n "$deploy" ]   && out="${out}${sep}${deploy# }"
printf "%b" "$out"
