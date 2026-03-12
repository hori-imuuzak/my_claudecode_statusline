#!/bin/sh
input=$(cat)

# --- Model ---
model=$(echo "$input" | jq -r '.model.display_name // "Unknown"')

# --- Gradient progress bar helper ---
# Usage: build_gradient_bar <percentage_int>
# Outputs: gradient bar string (15 chars wide) with ANSI truecolor
# Colors: green(0%) → yellow(50%) → red(100%)
RST="\033[0m"
DIM="\033[38;2;60;60;60m"
build_gradient_bar() {
  _pct=$1
  _width=15
  _filled=$(echo "$_pct" | awk -v w="$_width" '{f=int($1/100*w+0.5); if(f>w)f=w; if(f<0)f=0; print f}')
  _empty=$((_width - _filled))
  _bar=""
  _i=0
  while [ $_i -lt $_filled ]; do
    # Position ratio (0.0 to 1.0) based on absolute position in full bar
    _rgb=$(echo "$_i $_width" | awk '{
      ratio = ($1 / ($2 - 1 > 0 ? $2 - 1 : 1))
      if (ratio <= 0.5) {
        r = int(46 + (255 - 46) * ratio * 2)
        g = int(204 + (220 - 204) * ratio * 2)
        b = int(113 + (50 - 113) * ratio * 2)
      } else {
        r = int(255 + (239 - 255) * (ratio - 0.5) * 2)
        g = int(220 + (68 - 220) * (ratio - 0.5) * 2)
        b = int(50 + (68 - 50) * (ratio - 0.5) * 2)
      }
      printf "%d;%d;%d", r, g, b
    }')
    _bar="${_bar}\033[38;2;${_rgb}m█"
    _i=$((_i + 1))
  done
  _i=0
  while [ $_i -lt $_empty ]; do
    _bar="${_bar}${DIM}░"
    _i=$((_i + 1))
  done
  _bar="${_bar}${RST}"
  echo "$_bar"
}

# --- Context window ---
used_pct=$(echo "$input" | jq -r '.context_window.used_percentage // empty')

if [ -n "$used_pct" ]; then
  pct_int=$(echo "$used_pct" | awk '{printf "%d", $1}')
  ctx_bar=$(build_gradient_bar "$pct_int")
  ctx_display="${ctx_bar} ${used_pct}%"
else
  ctx_display="${DIM}░░░░░░░░░░░░░░░${RST} --"
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
if git -C "$cwd" rev-parse --git-dir > /dev/null 2>&1; then
  repo_root=$(GIT_OPTIONAL_LOCKS=0 git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)
  repo_name=$(basename "$repo_root" 2>/dev/null)
  git_branch=$(GIT_OPTIONAL_LOCKS=0 git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null)
  if [ -z "$git_branch" ]; then
    git_branch=$(GIT_OPTIONAL_LOCKS=0 git -C "$cwd" rev-parse --short HEAD 2>/dev/null)
    git_branch="(${git_branch})"
  fi
  git_info="${repo_name} 🌿 ${git_branch}"
fi

# --- OSC 8 link helper ---
# Usage: osc_link <file_path> <display_text>
osc_link() {
  printf '\033]8;;file://%s\033\\%s\033]8;;\033\\' "$1" "$2"
}

# --- Reference files (OSC 8 clickable links) ---
ref_links=""

# Memory.md
memory_dir="$HOME/.claude/projects"
if [ -n "$cwd" ]; then
  # Derive project memory path from cwd
  project_key=$(echo "$cwd" | sed 's|/|-|g')
  memory_file="${memory_dir}/${project_key}/memory/MEMORY.md"
  if [ -f "$memory_file" ]; then
    ref_links="$(osc_link "$memory_file" "MEMORY.md")"
  fi
fi

# Plan files: search for .md files in .claude/plans/ or project memory
plan_links=""
if [ -n "$cwd" ]; then
  # Check project memory directory for plan files
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
  # Check .claude/plans/ in the repo root for plan files
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

# --- ccusage block info ---
# Session block cost limit (USD) - adjust if plan changes
BLOCK_COST_LIMIT=10.0 # 契約プランに応じて調整

block_display=""
ccusage_block=$(bun x ccusage blocks --active --json 2>/dev/null || true)
if [ -n "$ccusage_block" ]; then
  is_active=$(echo "$ccusage_block" | jq -r '.blocks[0].isActive // empty')
  if [ "$is_active" = "true" ]; then
    cost=$(echo "$ccusage_block" | jq -r '.blocks[0].costUSD // empty')
    remaining=$(echo "$ccusage_block" | jq -r '.blocks[0].projection.remainingMinutes // empty')
    if [ -n "$cost" ]; then
      pct_int=$(echo "$cost" | awk -v limit="$BLOCK_COST_LIMIT" '{printf "%d", ($1 / limit * 100)}')
      limit_bar=$(build_gradient_bar "$pct_int")
      limit_display="${limit_bar} ${pct_int}%"
      # Time remaining
      time_display=""
      if [ -n "$remaining" ] && [ "$remaining" != "null" ]; then
        hours=$((remaining / 60))
        mins=$((remaining % 60))
        if [ "$hours" -gt 0 ]; then
          time_display="🕐 ${hours}h ${mins}m left"
        else
          time_display="🕐 ${mins}m left"
        fi
      fi
      block_display="${limit_display}"
      if [ -n "$time_display" ]; then
        block_display="${block_display} | ${time_display}"
      fi
    fi
  else
    block_display="░░░░░░░░░░░░░░░ --"
  fi
fi

# --- Assemble output ---
# Line 1: 📁 directory
# Line 2: 🔀 repo/branch
# Line 3: 🧠 context | 💪 model
# Line 4: 📊 limit | 🕐 time left
# Line 5: 📎 reference file links (if any)

line1="📁 ${cwd_short}"
line2=""
if [ -n "$git_info" ]; then
  line2="🔀 ${git_info}"
fi
line3="🧠 ${ctx_display} | 💪 ${model}"
line4=""
if [ -n "$block_display" ]; then
  line4="📊 ${block_display}"
fi
line5=""
if [ -n "$ref_links" ]; then
  line5="📎 ${ref_links}"
fi

output="$line1"
if [ -n "$line2" ]; then
  output="${output}\n${line2}"
fi
output="${output}\n${line3}"
if [ -n "$line4" ]; then
  output="${output}\n${line4}"
fi
if [ -n "$line5" ]; then
  output="${output}\n${line5}"
fi
printf "%b" "$output"
