#!/bin/sh
input=$(cat)

# --- Colors (basic ANSI only) ---
# Use printf to generate actual ESC sequences, not literal \033
RST=$(printf '\033[0m')
DIM=$(printf '\033[2m')
GREEN=$(printf '\033[32m')
YELLOW=$(printf '\033[33m')
RED=$(printf '\033[31m')

# --- Simple progress bar (basic 3-color) ---
# Usage: build_bar <percentage_int>
build_bar() {
  _pct=$1
  _width=10
  _filled=$(( _pct * _width / 100 ))
  [ "$_filled" -gt "$_width" ] && _filled=$_width
  [ "$_filled" -lt 0 ] && _filled=0
  _empty=$(( _width - _filled ))

  # Pick color by threshold
  if [ "$_pct" -lt 50 ]; then
    _color="$GREEN"
  elif [ "$_pct" -lt 80 ]; then
    _color="$YELLOW"
  else
    _color="$RED"
  fi

  _bar="${_color}"
  _i=0
  while [ $_i -lt $_filled ]; do
    _bar="${_bar}█"
    _i=$((_i + 1))
  done
  _bar="${_bar}${DIM}"
  _i=0
  while [ $_i -lt $_empty ]; do
    _bar="${_bar}░"
    _i=$((_i + 1))
  done
  _bar="${_bar}${RST}"
  printf '%s' "$_bar"
}

# --- Model ---
model=$(echo "$input" | jq -r '.model.display_name // "Unknown"')

# --- Context window ---
used_pct=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
if [ -n "$used_pct" ]; then
  pct_int=$(echo "$used_pct" | awk '{printf "%d", $1}')
  ctx_bar=$(build_bar "$pct_int")
  ctx_display="${ctx_bar} ${used_pct}%"
else
  ctx_display="${DIM}░░░░░░░░░░${RST} --"
fi

# --- Current working directory (abbreviated) ---
cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd // empty')
if [ -z "$cwd" ]; then
  cwd=$(pwd)
fi
home_dir="$HOME"
cwd_short=$(basename "$cwd")

# --- Git repo name + branch ---
git_info=""
repo_root=""
if git -C "$cwd" rev-parse --git-dir > /dev/null 2>&1; then
  repo_root=$(GIT_OPTIONAL_LOCKS=0 git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)
  repo_name=$(basename "$repo_root" 2>/dev/null)
  git_branch=$(GIT_OPTIONAL_LOCKS=0 git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null)
  if [ -z "$git_branch" ]; then
    git_branch=$(GIT_OPTIONAL_LOCKS=0 git -C "$cwd" rev-parse --short HEAD 2>/dev/null)
    git_branch="(${git_branch})"
  fi
  git_info="${git_branch}"
fi

# --- OSC 8 link helper ---
osc_link() {
  printf '\033]8;;file://%s\033\\%s\033]8;;\033\\' "$1" "$2"
}

# --- Reference files (OSC 8 clickable links) ---
ref_links=""
memory_dir="$HOME/.claude/projects"
if [ -n "$cwd" ]; then
  project_key=$(echo "$cwd" | sed 's|[/_]|-|g')
  memory_file="${memory_dir}/${project_key}/memory/MEMORY.md"
  if [ -f "$memory_file" ]; then
    ref_links="$(osc_link "$memory_file" "MEMORY.md")"
  fi
fi

plan_links=""
if [ -n "$cwd" ]; then
  project_memory_dir="${memory_dir}/${project_key}/memory"
  if [ -d "$project_memory_dir" ]; then
    for f in "$project_memory_dir"/*.md; do
      [ -f "$f" ] || continue
      fname=$(basename "$f")
      [ "$fname" = "MEMORY.md" ] && continue
      if [ -n "$plan_links" ]; then
        plan_links="${plan_links} $(osc_link "$f" "$fname")"
      else
        plan_links="$(osc_link "$f" "$fname")"
      fi
    done
  fi
  if [ -n "$repo_root" ] && [ -d "${repo_root}/.claude/plans" ]; then
    for f in "${repo_root}/.claude/plans"/*.md; do
      [ -f "$f" ] || continue
      fname=$(basename "$f")
      if [ -n "$plan_links" ]; then
        plan_links="${plan_links} $(osc_link "$f" "$fname")"
      else
        plan_links="$(osc_link "$f" "$fname")"
      fi
    done
  fi
fi

if [ -n "$plan_links" ]; then
  if [ -n "$ref_links" ]; then
    ref_links="${ref_links} | ${plan_links}"
  else
    ref_links="${plan_links}"
  fi
fi

# --- Rate limits (official: five_hour / seven_day) ---
format_remaining() {
  _reset_at=$1
  _now=$(date +%s)
  _diff=$(( _reset_at - _now ))
  if [ "$_diff" -le 0 ]; then
    printf '%s' "now"
    return
  fi
  _hours=$(( _diff / 3600 ))
  _mins=$(( (_diff % 3600) / 60 ))
  if [ "$_hours" -gt 0 ]; then
    printf '%s' "${_hours}h${_mins}m"
  else
    printf '%s' "${_mins}m"
  fi
}

five_hour_display=""
five_hour_pct=$(echo "$input" | jq -r '.rate_limits.five_hour.used_percentage // empty')
if [ -n "$five_hour_pct" ]; then
  five_pct_int=$(echo "$five_hour_pct" | awk '{printf "%d", $1}')
  five_bar=$(build_bar "$five_pct_int")
  five_reset=$(echo "$input" | jq -r '.rate_limits.five_hour.resets_at // empty')
  five_time=""
  if [ -n "$five_reset" ]; then
    five_time="$(format_remaining "$five_reset")"
  fi
  five_hour_display="${five_bar} ${five_pct_int}%"
  if [ -n "$five_time" ]; then
    five_hour_display="${five_hour_display}(${five_time})"
  fi
fi

seven_day_display=""
seven_day_pct=$(echo "$input" | jq -r '.rate_limits.seven_day.used_percentage // empty')
if [ -n "$seven_day_pct" ]; then
  seven_pct_int=$(echo "$seven_day_pct" | awk '{printf "%d", $1}')
  seven_bar=$(build_bar "$seven_pct_int")
  seven_reset=$(echo "$input" | jq -r '.rate_limits.seven_day.resets_at // empty')
  seven_time=""
  if [ -n "$seven_reset" ]; then
    seven_time="$(format_remaining "$seven_reset")"
  fi
  seven_day_display="${seven_bar} ${seven_pct_int}%"
  if [ -n "$seven_time" ]; then
    seven_day_display="${seven_day_display}(${seven_time})"
  fi
fi

# --- Assemble output (3 lines) ---
# Line 1: dir | repo:branch
# Line 2: ctx bar | model | cost bar
# Line 3: reference links (if any)

line1="📁 ${cwd_short}"
if [ -n "$git_info" ]; then
  line1="${line1} | 🔀 ${git_info}"
fi

line2="🧠 ${ctx_display} | 💪 ${model}"
if [ -n "$five_hour_display" ]; then
  line2="${line2} | ⏱ ${five_hour_display}"
fi
if [ -n "$seven_day_display" ]; then
  line2="${line2} | 📅 ${seven_day_display}"
fi

if [ -n "$ref_links" ]; then
  printf '%s\n%s\n📎 %s' "$line1" "$line2" "$ref_links"
else
  printf '%s\n%s' "$line1" "$line2"
fi
