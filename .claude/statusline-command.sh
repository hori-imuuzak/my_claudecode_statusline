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
cwd_short="${cwd#$home_dir}"
if [ "$cwd_short" != "$cwd" ]; then
  cwd_short="~$cwd_short"
fi
if [ ${#cwd_short} -gt 40 ]; then
  cwd_short=$(echo "$cwd_short" | awk -F/ '{
    n = NF;
    if (n >= 2) printf ".../%s/%s", $(n-1), $n;
    else print $0
  }')
fi

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
  git_info="${repo_name}:${git_branch}"
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

# --- ccusage block info (cached for 10 seconds) ---
BLOCK_COST_LIMIT=100
CACHE_FILE="/tmp/claude-statusline-ccusage.cache"
CACHE_TTL=10

block_display=""
# Check cache freshness
use_cache=false
if [ -f "$CACHE_FILE" ]; then
  cache_age=$(( $(date +%s) - $(stat -f %m "$CACHE_FILE" 2>/dev/null || echo 0) ))
  if [ "$cache_age" -lt "$CACHE_TTL" ]; then
    use_cache=true
  fi
fi

if [ "$use_cache" = true ]; then
  ccusage_block=$(cat "$CACHE_FILE")
else
  ccusage_block=$(bun x ccusage blocks --active --json 2>/dev/null || true)
  if [ -n "$ccusage_block" ]; then
    echo "$ccusage_block" > "$CACHE_FILE"
  fi
fi

if [ -n "$ccusage_block" ]; then
  is_active=$(echo "$ccusage_block" | jq -r '.blocks[0].isActive // empty')
  if [ "$is_active" = "true" ]; then
    cost=$(echo "$ccusage_block" | jq -r '.blocks[0].costUSD // empty')
    remaining=$(echo "$ccusage_block" | jq -r '.blocks[0].projection.remainingMinutes // empty')
    if [ -n "$cost" ]; then
      pct_int=$(echo "$cost" | awk -v limit="$BLOCK_COST_LIMIT" '{printf "%d", ($1 / limit * 100)}')
      limit_bar=$(build_bar "$pct_int")
      time_display=""
      if [ -n "$remaining" ] && [ "$remaining" != "null" ]; then
        hours=$((remaining / 60))
        mins=$((remaining % 60))
        if [ "$hours" -gt 0 ]; then
          time_display="${hours}h${mins}m"
        else
          time_display="${mins}m"
        fi
      fi
      block_display="${limit_bar} ${pct_int}%"
      if [ -n "$time_display" ]; then
        block_display="${block_display}(${time_display})"
      fi
    fi
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
if [ -n "$block_display" ]; then
  line2="${line2} | 📊 ${block_display}"
fi

if [ -n "$ref_links" ]; then
  printf '%s\n%s\n📎 %s' "$line1" "$line2" "$ref_links"
else
  printf '%s\n%s' "$line1" "$line2"
fi
