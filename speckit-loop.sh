#!/bin/bash

# =============================================================================
# Speckit Automation Loop
# =============================================================================
# Iterates through all specs in IMPLEMENTATION_ROADMAP.md and runs the full
# speckit workflow (specify -> plan -> tasks -> implement) for each spec.
#
# Supports both new format (## Spec 001:) and legacy format (## Phase 1:)
#
# Each command runs with fresh context (separate Claude processes).
# The implement step loops until all tasks are complete or stuck.
#
# FEATURES:
# - Automatic rate limit detection and waiting
#   When "You've hit your limit - resets Xam/pm (Timezone)" is detected,
#   the script automatically waits until the reset time + buffer, then resumes.
# - Progress tracking via .speckit-progress.json (can resume after interruption)
# - Automatic git commits after each spec completes
# - Backward compatible with Phase-based roadmaps
#
# USAGE:
#   ./speckit-loop.sh                    # Run from project directory
#   ./speckit-loop.sh /path/to/project   # Specify project directory
#   WORKDIR=/path/to/project ./speckit-loop.sh  # Via environment variable
# =============================================================================

set -e

# -----------------------------------------------------------------------------
# CONFIGURATION
# -----------------------------------------------------------------------------

# Working directory - can be set via:
# 1. Command line argument: ./speckit-loop.sh /path/to/project
# 2. Environment variable: WORKDIR=/path/to/project ./speckit-loop.sh
# 3. Default: current directory
if [[ -n "$1" ]]; then
  WORKDIR="$1"
elif [[ -z "$WORKDIR" ]]; then
  WORKDIR="$(pwd)"
fi

# Ensure WORKDIR is absolute path
WORKDIR="$(cd "$WORKDIR" && pwd)"

# File paths (relative to WORKDIR)
ROADMAP_FILE="${ROADMAP_FILE:-$WORKDIR/IMPLEMENTATION_ROADMAP.md}"
PROGRESS_FILE="${PROGRESS_FILE:-$WORKDIR/.speckit-progress.json}"
LOG_DIR="${LOG_DIR:-$WORKDIR/logs}"
SPECS_DIR="${SPECS_DIR:-$WORKDIR/specs}"

# Implement loop settings
MAX_IMPLEMENT_STUCK="${MAX_IMPLEMENT_STUCK:-3}"      # Exit implement loop after N iterations with no progress
MAX_COMMAND_RETRIES="${MAX_COMMAND_RETRIES:-3}"      # Retry failed commands up to N times
SLEEP_BETWEEN_COMMANDS="${SLEEP_BETWEEN_COMMANDS:-2}" # Seconds to wait between commands

# Rate limit settings
RATE_LIMIT_BUFFER_MINUTES="${RATE_LIMIT_BUFFER_MINUTES:-2}"  # Extra minutes to wait after reset time

# Feature flags
ENABLE_GIT_COMMITS="${ENABLE_GIT_COMMITS:-true}"     # Auto-commit after each phase
ENABLE_MIGRATION_CHECK="${ENABLE_MIGRATION_CHECK:-false}"  # Check Supabase migrations (set to true if using Supabase)

# -----------------------------------------------------------------------------
# COLORS & FORMATTING
# -----------------------------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# -----------------------------------------------------------------------------
# MIGRATION VERIFICATION (Optional - for Supabase projects)
# -----------------------------------------------------------------------------

# Check for unapplied Supabase migrations and apply them if needed
verify_migrations_applied() {
  if [[ "$ENABLE_MIGRATION_CHECK" != "true" ]]; then
    return 0
  fi

  echo ""
  echo -e "${BLUE}+------------------------------------------------------------------------------+${NC}"
  echo -e "${BLUE}|  VERIFYING DATABASE MIGRATIONS                                               |${NC}"
  echo -e "${BLUE}+------------------------------------------------------------------------------+${NC}"
  echo ""

  cd "$WORKDIR" || return 1

  # Check if supabase directory exists
  if [[ ! -d "$WORKDIR/supabase/migrations" ]]; then
    echo -e "${YELLOW}  No supabase/migrations directory found, skipping migration check${NC}"
    return 0
  fi

  # Count local migration files
  local local_count=$(find "$WORKDIR/supabase/migrations" -name "*.sql" -type f 2>/dev/null | wc -l | tr -d ' ')

  if [[ "$local_count" -eq 0 ]]; then
    echo -e "${YELLOW}  No migration files found, skipping migration check${NC}"
    return 0
  fi

  echo -e "${BLUE}  Found $local_count local migration files${NC}"

  # Get migration status
  local migration_output=$(npx supabase migration list --linked 2>&1)

  if echo "$migration_output" | grep -qi "error\|failed\|not linked"; then
    echo -e "${YELLOW}  Could not check migration status (project may not be linked)${NC}"
    echo -e "${YELLOW}  Run 'npx supabase link' to link your project${NC}"
    return 0
  fi

  # Parse for unapplied migrations
  local local_migrations=$(echo "$migration_output" | grep -oE '^\s+[0-9]{14}' | tr -d ' ' | sort -u)
  local remote_migrations=$(echo "$migration_output" | grep -oE '\|\s+[0-9]{14}\s+\|' | grep -oE '[0-9]{14}' | sort -u)

  local missing=""
  for local_id in $local_migrations; do
    if ! echo "$remote_migrations" | grep -q "^${local_id}$"; then
      missing="$missing $local_id"
    fi
  done

  if [[ -z "$missing" || "$missing" == " " ]]; then
    echo -e "${GREEN}  All migrations are applied to remote database${NC}"
    return 0
  fi

  local missing_count=$(echo "$missing" | wc -w | tr -d ' ')
  echo -e "${YELLOW}  Found $missing_count unapplied migration(s)${NC}"
  echo ""
  echo -e "${BLUE}  Pushing migrations to remote database...${NC}"

  if npx supabase db push --linked 2>&1 | tee -a "$LOGFILE"; then
    echo -e "${GREEN}  Migrations applied successfully${NC}"

    # Regenerate TypeScript types
    if [[ -d "$WORKDIR/src/types" ]]; then
      echo -e "${BLUE}  Regenerating TypeScript types...${NC}"
      if npx supabase gen types typescript --linked > "$WORKDIR/src/types/database.ts" 2>&1; then
        echo -e "${GREEN}  TypeScript types regenerated${NC}"
      fi
    fi

    return 0
  else
    echo -e "${RED}  Failed to apply migrations${NC}"
    return 1
  fi
}

# -----------------------------------------------------------------------------
# LOGGING
# -----------------------------------------------------------------------------

setup_logging() {
  mkdir -p "$LOG_DIR"
  LOGFILE="$LOG_DIR/speckit-$(date +%Y%m%d-%H%M%S).log"
  echo "Logging to: $LOGFILE"
}

log() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
  echo "$msg" >> "$LOGFILE"
  echo -e "$1"
}

log_section() {
  echo "" >> "$LOGFILE"
  echo "========================================" >> "$LOGFILE"
  echo "$1" >> "$LOGFILE"
  echo "========================================" >> "$LOGFILE"
  echo ""
  echo -e "${CYAN}========================================${NC}"
  echo -e "${CYAN}$1${NC}"
  echo -e "${CYAN}========================================${NC}"
}

# -----------------------------------------------------------------------------
# RATE LIMIT HANDLING
# -----------------------------------------------------------------------------

# Check if output contains actual Claude rate limit message
check_rate_limit() {
  local output_file=$1

  # Look for the specific Claude rate limit message format
  if grep -qi "you've hit your limit" "$output_file" 2>/dev/null; then
    if grep -qi "resets [0-9]\+[ap]m" "$output_file" 2>/dev/null; then
      return 0  # Rate limited
    fi
  fi

  if grep -qi "hit your limit.*resets" "$output_file" 2>/dev/null; then
    return 0  # Rate limited
  fi

  return 1  # Not rate limited
}

# Parse reset time from output like "resets 10am (America/Toronto)"
parse_reset_time() {
  local output_file=$1

  local reset_line=$(grep -oi "resets [0-9]\+[ap]m\s*([^)]*)" "$output_file" 2>/dev/null | head -1)

  if [[ -z "$reset_line" ]]; then
    reset_line=$(grep -oi "resets [0-9]\+[ap]m" "$output_file" 2>/dev/null | head -1)
  fi

  if [[ -z "$reset_line" ]]; then
    echo "0"
    return
  fi

  local time_part=$(echo "$reset_line" | grep -oi "[0-9]\+[ap]m" | head -1)
  local hour=$(echo "$time_part" | grep -o "[0-9]\+")
  local ampm=$(echo "$time_part" | grep -oi "[ap]m")

  local timezone=$(echo "$reset_line" | grep -o "([^)]*)" | tr -d '()' | xargs)
  if [[ -z "$timezone" ]]; then
    timezone=$(date +%Z)  # Use system timezone as default
  fi

  # Convert to 24-hour format
  if [[ "${ampm,,}" == "pm" ]] && [[ "$hour" -lt 12 ]]; then
    hour=$((hour + 12))
  elif [[ "${ampm,,}" == "am" ]] && [[ "$hour" -eq 12 ]]; then
    hour=0
  fi

  local current_epoch=$(date +%s)

  # Use Python for timezone handling
  local target_epoch=$(python3 -c "
import datetime
import sys
try:
    from zoneinfo import ZoneInfo
except ImportError:
    from backports.zoneinfo import ZoneInfo

tz = ZoneInfo('$timezone')
now = datetime.datetime.now(tz)
target = now.replace(hour=$hour, minute=0, second=0, microsecond=0)

if target <= now:
    target = target + datetime.timedelta(days=1)

print(int(target.timestamp()))
" 2>/dev/null)

  if [[ -z "$target_epoch" ]] || [[ "$target_epoch" == "0" ]]; then
    echo "3600"
    return
  fi

  local seconds_until=$((target_epoch - current_epoch + RATE_LIMIT_BUFFER_MINUTES * 60))

  if [[ $seconds_until -lt 60 ]]; then
    seconds_until=60
  fi

  echo "$seconds_until"
}

format_duration() {
  local seconds=$1
  local hours=$((seconds / 3600))
  local minutes=$(((seconds % 3600) / 60))
  local secs=$((seconds % 60))

  if [[ $hours -gt 0 ]]; then
    printf "%dh %dm %ds" $hours $minutes $secs
  elif [[ $minutes -gt 0 ]]; then
    printf "%dm %ds" $minutes $secs
  else
    printf "%ds" $secs
  fi
}

wait_for_rate_limit_reset() {
  local seconds_to_wait=$1
  local reset_time=$(date -v+${seconds_to_wait}S '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -d "+${seconds_to_wait} seconds" '+%Y-%m-%d %H:%M:%S' 2>/dev/null)

  echo ""
  echo -e "${YELLOW}+==============================================================================+${NC}"
  echo -e "${YELLOW}|  RATE LIMIT REACHED - WAITING FOR RESET                                     |${NC}"
  echo -e "${YELLOW}+------------------------------------------------------------------------------+${NC}"
  echo -e "${YELLOW}|  Reset time: $reset_time                                      ${NC}"
  echo -e "${YELLOW}|  Wait duration: $(format_duration $seconds_to_wait)                                              ${NC}"
  echo -e "${YELLOW}+==============================================================================+${NC}"
  echo ""

  log "Rate limit reached. Waiting $seconds_to_wait seconds until $reset_time"

  local remaining=$seconds_to_wait
  local update_interval=300

  while [[ $remaining -gt 0 ]]; do
    if [[ $remaining -le 60 ]]; then
      echo -ne "\r${BLUE}  Resuming in $(format_duration $remaining)...${NC}    "
      sleep 10
      remaining=$((remaining - 10))
    elif [[ $remaining -le $update_interval ]]; then
      echo -e "${BLUE}  Resuming in $(format_duration $remaining)...${NC}"
      sleep 60
      remaining=$((remaining - 60))
    else
      echo -e "${BLUE}  Resuming in $(format_duration $remaining)... (next update in 5 min)${NC}"
      sleep $update_interval
      remaining=$((remaining - update_interval))
    fi
  done

  echo ""
  echo -e "${GREEN}  Rate limit reset! Resuming...${NC}"
  echo ""
  log "Rate limit reset. Resuming execution."
}

# -----------------------------------------------------------------------------
# PROGRESS TRACKING
# -----------------------------------------------------------------------------

init_progress() {
  if [[ ! -f "$PROGRESS_FILE" ]]; then
    echo '{"current_phase": 0, "phases": {}}' > "$PROGRESS_FILE"
  fi
}

get_current_phase() {
  jq -r '.current_phase' "$PROGRESS_FILE"
}

get_phase_status() {
  local phase_num=$1
  local step=$2
  jq -r ".phases[\"$phase_num\"][\"$step\"] // \"pending\"" "$PROGRESS_FILE"
}

set_phase_status() {
  local phase_num=$1
  local step=$2
  local status=$3

  local tmp=$(mktemp)
  jq ".phases[\"$phase_num\"][\"$step\"] = \"$status\"" "$PROGRESS_FILE" > "$tmp"
  mv "$tmp" "$PROGRESS_FILE"
}

set_current_phase() {
  local phase_num=$1
  local tmp=$(mktemp)
  jq ".current_phase = $phase_num" "$PROGRESS_FILE" > "$tmp"
  mv "$tmp" "$PROGRESS_FILE"
}

# -----------------------------------------------------------------------------
# SPEC PARSING
# -----------------------------------------------------------------------------

# Get all spec numbers from the roadmap
# Supports both "## Spec 001:" and "## Phase 1:" formats
get_spec_numbers() {
  # Try new format first (Spec NNN:)
  local specs=$(grep -E '^## Spec [0-9]+:' "$ROADMAP_FILE" | sed -E 's/^## Spec ([0-9]+):.*/\1/' | sort -n)

  if [[ -n "$specs" ]]; then
    echo "$specs"
  else
    # Fall back to old format (Phase N:)
    grep -E '^## Phase [0-9]+:' "$ROADMAP_FILE" | sed -E 's/^## Phase ([0-9]+):.*/\1/' | sort -n
  fi
}

# Alias for backward compatibility
get_phase_numbers() {
  get_spec_numbers
}

# Get the title of a spec/phase
get_spec_title() {
  local spec_num=$1
  local spec_padded=$(printf "%03d" "$spec_num")

  # Try new format first (Spec NNN:)
  local title=$(grep -E "^## Spec 0*$spec_num:" "$ROADMAP_FILE" | sed -E "s/^## Spec 0*$spec_num: //")

  if [[ -z "$title" ]]; then
    # Fall back to old format (Phase N:)
    title=$(grep -E "^## Phase $spec_num:" "$ROADMAP_FILE" | sed -E "s/^## Phase $spec_num: //")
  fi

  echo "$title"
}

# Alias for backward compatibility
get_phase_title() {
  get_spec_title "$1"
}

# Get the purpose/goal of a spec
get_spec_purpose() {
  local spec_num=$1
  local spec_padded=$(printf "%03d" "$spec_num")

  # Try new format first (### Purpose section)
  local purpose=$(awk "/^## Spec 0*$spec_num:/{found=1} found && /^### Purpose/{getline; while(/^[^#]/ && !/^$/) {print; getline}; exit}" "$ROADMAP_FILE" | head -1 | sed 's/^[[:space:]]*//')

  if [[ -z "$purpose" ]]; then
    # Fall back to old format (**Goal**:)
    purpose=$(awk "/^## Phase $spec_num:/{found=1} found && /^\*\*Goal\*\*:/{print; exit}" "$ROADMAP_FILE" | sed 's/\*\*Goal\*\*: //')
  fi

  echo "$purpose"
}

# Alias for backward compatibility
get_phase_goal() {
  get_spec_purpose "$1"
}

# Get success criteria/tasks for a spec
get_spec_criteria() {
  local spec_num=$1
  local spec_padded=$(printf "%03d" "$spec_num")
  local next_spec=$((spec_num + 1))
  local next_spec_padded=$(printf "%03d" "$next_spec")

  # Try new format first (### Success Criteria section)
  local criteria=$(awk "/^## Spec 0*$spec_num:/,/^## Spec|^## Implementation|^## Risk|^---$/" "$ROADMAP_FILE" \
    | awk '/^### Success Criteria/,/^###/' \
    | grep -E '^\- \[' \
    | sed 's/- \[ \] /- /' \
    | head -20)

  if [[ -z "$criteria" ]]; then
    # Fall back to old format (### Tasks section or inline tasks)
    criteria=$(awk "/^## Phase $spec_num:/,/^## Phase $next_spec:|^## Implementation Order|^## Notes|^---$/" "$ROADMAP_FILE" \
      | grep -E '^\- \[' \
      | sed 's/- \[ \] /- /' \
      | head -20)
  fi

  echo "$criteria"
}

# Alias for backward compatibility
get_phase_tasks() {
  get_spec_criteria "$1"
}

# Switch to the branch for a spec
switch_to_spec_branch() {
  local spec_num=$1
  local spec_prefix=$(printf "%03d" "$spec_num")

  cd "$WORKDIR" || return 1

  # Try 3-digit prefix first (001-, 002-, etc.)
  local branch=$(git branch -a | grep -E "^\*?\s*${spec_prefix}-" | head -1 | sed 's/^\*\?\s*//' | xargs)

  if [[ -z "$branch" ]]; then
    # Try without leading zeros
    branch=$(git branch -a | grep -E "^\*?\s*${spec_num}-" | head -1 | sed 's/^\*\?\s*//' | xargs)
  fi

  if [[ -n "$branch" ]]; then
    local current_branch=$(git branch --show-current)
    if [[ "$current_branch" != "$branch" ]]; then
      echo -e "${BLUE}  Switching to branch: $branch${NC}"
      git checkout "$branch" 2>/dev/null || git checkout -b "$branch" 2>/dev/null
    else
      echo -e "${GREEN}  Already on branch: $branch${NC}"
    fi
    return 0
  else
    echo -e "${YELLOW}  No branch found for spec $spec_num${NC}"
    return 1
  fi
}

# Alias for backward compatibility
switch_to_phase_branch() {
  switch_to_spec_branch "$1"
}

# Build a description for passing to speckit.specify
build_spec_description() {
  local spec_num=$1
  local spec_padded=$(printf "%03d" "$spec_num")
  local title=$(get_spec_title "$spec_num")
  local purpose=$(get_spec_purpose "$spec_num")
  local criteria=$(get_spec_criteria "$spec_num")

  cat <<EOF
Spec $spec_padded: $title

Purpose: $purpose

Success Criteria:
$criteria
EOF
}

# Alias for backward compatibility
build_phase_description() {
  build_spec_description "$1"
}

mark_spec_complete_in_roadmap() {
  local spec_num=$1
  local spec_padded=$(printf "%03d" "$spec_num")

  echo ""
  echo -e "${BLUE}  Marking Spec $spec_padded criteria as complete in IMPLEMENTATION_ROADMAP.md...${NC}"

  local tmp=$(mktemp)

  # Handle both Spec NNN: and Phase N: formats
  awk -v spec="$spec_num" -v spec_padded="$spec_padded" '
    BEGIN { in_spec = 0 }
    /^## Spec [0-9]+:/ {
      # Check if this is our spec (with or without leading zeros)
      if ($0 ~ "^## Spec 0*" spec ":") {
        in_spec = 1
      } else {
        in_spec = 0
      }
    }
    /^## Phase [0-9]+:/ {
      if ($0 ~ "^## Phase " spec ":") {
        in_spec = 1
      } else {
        in_spec = 0
      }
    }
    {
      if (in_spec && /^- \[ \]/) {
        gsub(/^- \[ \]/, "- [x]")
      }
      print
    }
  ' "$ROADMAP_FILE" > "$tmp"

  mv "$tmp" "$ROADMAP_FILE"
  echo -e "${GREEN}  Roadmap updated - Spec $spec_padded criteria marked [x]${NC}"
}

# Alias for backward compatibility
mark_phase_complete_in_roadmap() {
  mark_spec_complete_in_roadmap "$1"
}

commit_spec_changes() {
  if [[ "$ENABLE_GIT_COMMITS" != "true" ]]; then
    return 0
  fi

  local spec_num=$1
  local spec_padded=$(printf "%03d" "$spec_num")
  local title=$(get_spec_title "$spec_num")

  echo ""
  echo -e "${BLUE}+------------------------------------------------------------------------------+${NC}"
  echo -e "${BLUE}|  GIT COMMIT - Spec $spec_padded                                              ${NC}"
  echo -e "${BLUE}+------------------------------------------------------------------------------+${NC}"
  echo ""

  cd "$WORKDIR" || return 1

  echo -e "${BLUE}  Staging all changes...${NC}"
  git add -A

  if git diff --cached --quiet; then
    echo -e "${YELLOW}  No changes to commit for Spec $spec_padded${NC}"
    return 0
  fi

  echo -e "${BLUE}  Changes to be committed:${NC}"
  git diff --cached --stat | head -20
  echo ""

  local commit_msg="feat: Complete Spec $spec_padded - $title

Automated commit by speckit-loop.sh

Generated with Claude Code

Co-Authored-By: Claude <noreply@anthropic.com>"

  echo -e "${BLUE}  Creating commit...${NC}"
  if git commit -m "$commit_msg"; then
    echo ""
    echo -e "${GREEN}  COMMITTED: Spec $spec_padded - $title${NC}"
    echo -e "${GREEN}  $(git log -1 --oneline)${NC}"
  else
    echo -e "${RED}  Failed to commit Spec $spec_padded changes${NC}"
    return 1
  fi
}

# Alias for backward compatibility
commit_phase_changes() {
  commit_spec_changes "$1"
}

# -----------------------------------------------------------------------------
# SPECKIT COMMAND EXECUTION
# -----------------------------------------------------------------------------

run_speckit_command() {
  local command=$1
  local args=$2
  local retry_count=0
  local success=false
  local output_file=$(mktemp)

  while [[ $retry_count -lt $MAX_COMMAND_RETRIES ]] && [[ "$success" == "false" ]]; do
    retry_count=$((retry_count + 1))

    if [[ $retry_count -gt 1 ]]; then
      echo ""
      echo -e "${YELLOW}----------------------------------------------------${NC}"
      echo -e "${YELLOW}  RETRY $retry_count/$MAX_COMMAND_RETRIES for /$command${NC}"
      echo -e "${YELLOW}----------------------------------------------------${NC}"
    fi

    echo ""
    echo -e "${CYAN}============================================================================${NC}"
    echo -e "${CYAN}  EXECUTING: /$command${NC}"
    echo -e "${CYAN}============================================================================${NC}"
    echo ""
    echo -e "${BLUE}  Working directory: $WORKDIR${NC}"
    echo -e "${BLUE}  Timestamp: $(date '+%Y-%m-%d %H:%M:%S')${NC}"
    if [[ -n "$args" ]]; then
      echo -e "${BLUE}  Arguments: ${args:0:100}...${NC}"
    fi
    echo ""
    echo -e "${GREEN}  --- CLAUDE OUTPUT BELOW ---${NC}"
    echo ""

    # Heartbeat to show script is alive
    local heartbeat_pid=""
    (
      local elapsed=0
      while true; do
        sleep 60
        elapsed=$((elapsed + 1))
        echo -e "\n${BLUE}  Still running... (${elapsed}m elapsed)${NC}" >&2
      done
    ) &
    heartbeat_pid=$!

    > "$output_file"
    local claude_result=0
    if command -v stdbuf >/dev/null 2>&1; then
      if cd "$WORKDIR" && stdbuf -oL -eL claude --print --dangerously-skip-permissions "/$command $args" 2>&1 | tee -a "$LOGFILE" | tee "$output_file"; then
        claude_result=0
      else
        claude_result=$?
      fi
    else
      if cd "$WORKDIR" && claude --print --dangerously-skip-permissions "/$command $args" 2>&1 | tee -a "$LOGFILE" | tee "$output_file"; then
        claude_result=0
      else
        claude_result=$?
      fi
    fi

    kill $heartbeat_pid 2>/dev/null
    wait $heartbeat_pid 2>/dev/null

    if [[ $claude_result -eq 0 ]]; then
      if check_rate_limit "$output_file"; then
        echo ""
        echo -e "${YELLOW}  Rate limit detected in output${NC}"

        local wait_seconds=$(parse_reset_time "$output_file")
        if [[ "$wait_seconds" -gt 0 ]]; then
          wait_for_rate_limit_reset "$wait_seconds"
          retry_count=0
          continue
        else
          echo -e "${YELLOW}  Could not parse reset time, waiting 1 hour as fallback${NC}"
          wait_for_rate_limit_reset 3600
          retry_count=0
          continue
        fi
      fi

      success=true
      echo ""
      echo -e "${GREEN}  --- CLAUDE OUTPUT ABOVE ---${NC}"
      echo ""
      echo -e "${GREEN}  /$command completed successfully${NC}"
    else
      echo ""

      if check_rate_limit "$output_file"; then
        echo -e "${YELLOW}  Rate limit detected (exit code: $claude_result)${NC}"

        local wait_seconds=$(parse_reset_time "$output_file")
        if [[ "$wait_seconds" -gt 0 ]]; then
          wait_for_rate_limit_reset "$wait_seconds"
          retry_count=0
          continue
        else
          echo -e "${YELLOW}  Could not parse reset time, waiting 1 hour as fallback${NC}"
          wait_for_rate_limit_reset 3600
          retry_count=0
          continue
        fi
      fi

      echo -e "${RED}  Command failed, exit code: $claude_result${NC}"
      log "${RED}Command failed, exit code: $claude_result${NC}"
      sleep $SLEEP_BETWEEN_COMMANDS
    fi
  done

  rm -f "$output_file"

  if [[ "$success" == "false" ]]; then
    echo ""
    echo -e "${RED}----------------------------------------------------${NC}"
    echo -e "${RED}  ERROR: /$command failed after $MAX_COMMAND_RETRIES attempts${NC}"
    echo -e "${RED}----------------------------------------------------${NC}"
    return 1
  fi

  sleep $SLEEP_BETWEEN_COMMANDS
  return 0
}

# -----------------------------------------------------------------------------
# IMPLEMENT LOOP
# -----------------------------------------------------------------------------

find_tasks_file() {
  local branch=$(cd "$WORKDIR" && git branch --show-current 2>/dev/null)

  if [[ -n "$branch" ]]; then
    local spec_dir=$(find "$SPECS_DIR" -maxdepth 1 -type d -name "*${branch}*" 2>/dev/null | head -1)
    if [[ -n "$spec_dir" ]] && [[ -f "$spec_dir/tasks.md" ]]; then
      echo "$spec_dir/tasks.md"
      return 0
    fi
  fi

  # Fallback: most recently modified tasks.md
  if [[ "$(uname)" == "Darwin" ]]; then
    find "$SPECS_DIR" -name "tasks.md" -type f -exec stat -f '%m %N' {} \; 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-
  else
    find "$SPECS_DIR" -name "tasks.md" -type f -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-
  fi
}

count_remaining_tasks() {
  local tasks_file=$1
  local count=0
  if [[ -f "$tasks_file" ]]; then
    count=$(grep -c '^\- \[ \]' "$tasks_file" 2>/dev/null || echo "0")
  fi
  echo "$count" | tr -d '\n' | grep -o '[0-9]*' | head -1 || echo "0"
}

get_completed_tasks() {
  local tasks_file=$1
  grep '^\- \[x\]' "$tasks_file" 2>/dev/null | grep -oE 'T[0-9]+' | sort -u
}

get_pending_tasks() {
  local tasks_file=$1
  grep '^\- \[ \]' "$tasks_file" 2>/dev/null | grep -oE 'T[0-9]+' | sort -u
}

draw_progress_bar() {
  local completed=$1
  local total=$2
  local width=40

  if [[ $total -eq 0 ]]; then
    echo "[$(printf '=%.0s' $(seq 1 $width))] 0%"
    return
  fi

  local percent=$((completed * 100 / total))
  local filled=$((completed * width / total))
  local empty=$((width - filled))

  local bar=""
  if [[ $filled -gt 0 ]]; then
    bar+=$(printf '#%.0s' $(seq 1 $filled))
  fi
  if [[ $empty -gt 0 ]]; then
    bar+=$(printf '.%.0s' $(seq 1 $empty))
  fi

  printf "[%s] %3d%%" "$bar" "$percent"
}

show_task_status() {
  local tasks_file=$1
  local completed=$2
  local total=$3

  echo ""
  echo -e "${CYAN}+----------------------------------------------------------------------------+${NC}"
  echo -e "${CYAN}|  TASK PROGRESS                                                             |${NC}"
  echo -e "${CYAN}+----------------------------------------------------------------------------+${NC}"
  echo -e "${CYAN}|  $(draw_progress_bar $completed $total)  $completed/$total tasks  |${NC}"
  echo -e "${CYAN}+----------------------------------------------------------------------------+${NC}"
}

show_newly_completed_tasks() {
  local tasks_file=$1
  local previous_completed_file=$2

  if [[ ! -f "$previous_completed_file" ]]; then
    return
  fi

  local current_completed=$(get_completed_tasks "$tasks_file")
  local previous_completed=$(cat "$previous_completed_file" 2>/dev/null)

  local new_tasks=""
  for task_id in $current_completed; do
    if ! echo "$previous_completed" | grep -q "^${task_id}$"; then
      new_tasks="$new_tasks $task_id"
    fi
  done

  if [[ -n "$new_tasks" ]]; then
    echo ""
    echo -e "${GREEN}+------------------------------------------------------------------------------+${NC}"
    echo -e "${GREEN}|  NEWLY COMPLETED TASKS                                                       |${NC}"
    echo -e "${GREEN}+------------------------------------------------------------------------------+${NC}"
    for task_id in $new_tasks; do
      echo -e "${GREEN}|  [x] $task_id${NC}"
    done
    echo -e "${GREEN}+------------------------------------------------------------------------------+${NC}"
  fi
}

run_implement_loop() {
  local stuck_counter=0
  local previous_remaining=-1
  local iteration=0
  local completed_tracking_file=$(mktemp)
  local start_time=$(date +%s)
  local all_tasks_complete=false

  echo ""
  echo -e "${CYAN}+==============================================================================+${NC}"
  echo -e "${CYAN}|  IMPLEMENT LOOP STARTED                                                     |${NC}"
  echo -e "${CYAN}|  Will keep running until all tasks complete or no progress detected         |${NC}"
  echo -e "${CYAN}+==============================================================================+${NC}"
  echo ""

  while true; do
    iteration=$((iteration + 1))
    local iteration_start=$(date +%s)

    local tasks_file=$(find_tasks_file)

    if [[ -z "$tasks_file" ]] || [[ ! -f "$tasks_file" ]]; then
      echo -e "${YELLOW}  Warning: Could not find tasks.md file${NC}"
      echo -e "${YELLOW}  Running implement once without progress tracking...${NC}"
      run_speckit_command "speckit.implement" ""
      break
    fi

    local remaining=$(count_remaining_tasks "$tasks_file")
    local completed=$(grep -c '^\- \[x\]' "$tasks_file" 2>/dev/null | tr -d '\n' | grep -o '[0-9]*' | head -1 || echo "0")
    remaining=${remaining:-0}
    completed=${completed:-0}
    local total=$((completed + remaining))

    local elapsed=$(($(date +%s) - start_time))
    local elapsed_fmt=$(format_duration $elapsed)

    show_task_status "$tasks_file" "$completed" "$total"

    echo ""
    echo -e "${BLUE}+------------------------------------------------------------------------------+${NC}"
    echo -e "${BLUE}|  IMPLEMENT ITERATION #$iteration                                            ${NC}"
    echo -e "${BLUE}+------------------------------------------------------------------------------+${NC}"
    echo -e "${BLUE}|  Progress: $completed/$total tasks ($remaining remaining)                        ${NC}"
    echo -e "${BLUE}|  Tasks file: $(basename $(dirname "$tasks_file"))/tasks.md${NC}"
    echo -e "${BLUE}|  Time: $(date '+%H:%M:%S') (elapsed: $elapsed_fmt)                           ${NC}"
    echo -e "${BLUE}|  Stuck counter: $stuck_counter/$MAX_IMPLEMENT_STUCK                              ${NC}"
    echo -e "${BLUE}+------------------------------------------------------------------------------+${NC}"

    show_newly_completed_tasks "$tasks_file" "$completed_tracking_file"
    get_completed_tasks "$tasks_file" > "$completed_tracking_file"

    if [[ "$remaining" -eq 0 ]]; then
      echo ""
      echo -e "${GREEN}+==============================================================================+${NC}"
      echo -e "${GREEN}|  ALL $total TASKS COMPLETE!                                                  |${NC}"
      echo -e "${GREEN}|  Total time: $elapsed_fmt                                                    |${NC}"
      echo -e "${GREEN}+==============================================================================+${NC}"
      echo ""
      all_tasks_complete=true
      break
    fi

    echo ""
    echo -e "${YELLOW}+------------------------------------------------------------------------------+${NC}"
    echo -e "${YELLOW}|  NEXT TASKS TO COMPLETE                                                      |${NC}"
    echo -e "${YELLOW}+------------------------------------------------------------------------------+${NC}"
    local task_count=0
    while IFS= read -r task; do
      task_count=$((task_count + 1))
      local task_desc=$(echo "$task" | sed "s/^- \[ \] //" | cut -c1-65)
      if [[ $task_count -eq 1 ]]; then
        echo -e "${YELLOW}|  > $task_desc${NC}"
      else
        echo -e "${YELLOW}|    $task_desc${NC}"
      fi
      if [[ $task_count -ge 5 ]]; then
        break
      fi
    done < <(grep '^\- \[ \]' "$tasks_file" | head -5)
    echo -e "${YELLOW}+------------------------------------------------------------------------------+${NC}"
    echo ""

    if [[ "$remaining" -eq "$previous_remaining" ]]; then
      stuck_counter=$((stuck_counter + 1))
      echo -e "${YELLOW}  No progress detected (stuck count: $stuck_counter/$MAX_IMPLEMENT_STUCK)${NC}"

      if [[ $stuck_counter -ge $MAX_IMPLEMENT_STUCK ]]; then
        echo ""
        echo -e "${YELLOW}+==============================================================================+${NC}"
        echo -e "${YELLOW}|  IMPLEMENT LOOP STOPPED - NO PROGRESS                                       |${NC}"
        echo -e "${YELLOW}|  No progress after $MAX_IMPLEMENT_STUCK iterations                                  |${NC}"
        echo -e "${YELLOW}|  $remaining tasks may require manual intervention                             |${NC}"
        echo -e "${YELLOW}+==============================================================================+${NC}"
        echo ""
        break
      fi
    else
      if [[ $previous_remaining -gt 0 ]]; then
        local progress=$((previous_remaining - remaining))
        echo -e "${GREEN}  Progress! $progress task(s) completed in last iteration${NC}"
      fi
      stuck_counter=0
    fi
    previous_remaining=$remaining

    echo ""
    echo -e "${CYAN}============================================================================${NC}"
    echo -e "${CYAN}  Starting speckit.implement iteration #$iteration...${NC}"
    echo -e "${CYAN}============================================================================${NC}"

    if ! run_speckit_command "speckit.implement" ""; then
      echo -e "${RED}  Implement command failed${NC}"
      break
    fi

    local iteration_elapsed=$(($(date +%s) - iteration_start))
    echo ""
    echo -e "${BLUE}  Iteration #$iteration took $(format_duration $iteration_elapsed)${NC}"
  done

  rm -f "$completed_tracking_file"

  if [[ "$all_tasks_complete" == "true" ]]; then
    return 0
  else
    return 1
  fi
}

# -----------------------------------------------------------------------------
# SPEC WORKFLOW
# -----------------------------------------------------------------------------

run_spec_workflow() {
  local spec_num=$1
  local spec_padded=$(printf "%03d" "$spec_num")
  local title=$(get_spec_title "$spec_num")
  local description=$(build_spec_description "$spec_num")

  echo ""
  echo -e "${CYAN}+==============================================================================+${NC}"
  echo -e "${CYAN}|  SPEC $spec_padded: $title${NC}"
  echo -e "${CYAN}+==============================================================================+${NC}"
  echo ""
  echo -e "${BLUE}Purpose:${NC}"
  echo -e "  $(get_spec_purpose "$spec_num")"
  echo ""
  echo -e "${BLUE}Workflow Steps:${NC}"
  echo -e "  [1/4] speckit.specify  -> Create feature specification"
  echo -e "  [2/4] speckit.plan     -> Create implementation plan"
  echo -e "  [3/4] speckit.tasks    -> Generate task breakdown"
  echo -e "  [4/4] speckit.implement -> Execute tasks (loops until done)"
  echo ""

  # Step 1: Specify
  local specify_status=$(get_phase_status "$spec_num" "specify")
  if [[ "$specify_status" != "complete" ]]; then
    echo ""
    echo -e "${YELLOW}+------------------------------------------------------------------------------+${NC}"
    echo -e "${YELLOW}|  [1/4] SPECIFY - Creating feature specification                              |${NC}"
    echo -e "${YELLOW}+------------------------------------------------------------------------------+${NC}"
    echo ""

    set_phase_status "$spec_num" "specify" "in_progress"

    local escaped_desc=$(printf '%s' "$description" | sed "s/'/'\\\\''/g")

    if run_speckit_command "speckit.specify" "$escaped_desc"; then
      set_phase_status "$spec_num" "specify" "complete"
      echo -e "${GREEN}  [1/4] SPECIFY COMPLETE${NC}"
    else
      set_phase_status "$spec_num" "specify" "failed"
      echo -e "${RED}  [1/4] SPECIFY FAILED${NC}"
      return 1
    fi
  else
    echo -e "${GREEN}  [1/4] specify already complete, skipping${NC}"
  fi

  # Verify branch
  echo ""
  echo -e "${BLUE}  Verifying branch for Spec $spec_padded...${NC}"
  if ! switch_to_spec_branch "$spec_num"; then
    echo -e "${RED}  Could not find/switch to branch for Spec $spec_padded${NC}"
    set_phase_status "$spec_num" "specify" "pending"
    return 1
  fi
  echo ""

  # Step 2: Plan
  local plan_status=$(get_phase_status "$spec_num" "plan")
  if [[ "$plan_status" != "complete" ]]; then
    echo ""
    echo -e "${YELLOW}+------------------------------------------------------------------------------+${NC}"
    echo -e "${YELLOW}|  [2/4] PLAN - Creating implementation plan                                   |${NC}"
    echo -e "${YELLOW}+------------------------------------------------------------------------------+${NC}"
    echo ""

    set_phase_status "$spec_num" "plan" "in_progress"

    if run_speckit_command "speckit.plan" ""; then
      set_phase_status "$spec_num" "plan" "complete"
      echo -e "${GREEN}  [2/4] PLAN COMPLETE${NC}"
    else
      set_phase_status "$spec_num" "plan" "failed"
      echo -e "${RED}  [2/4] PLAN FAILED${NC}"
      return 1
    fi
  else
    echo -e "${GREEN}  [2/4] plan already complete, skipping${NC}"
  fi

  # Step 3: Tasks
  local tasks_status=$(get_phase_status "$spec_num" "tasks")
  if [[ "$tasks_status" != "complete" ]]; then
    echo ""
    echo -e "${YELLOW}+------------------------------------------------------------------------------+${NC}"
    echo -e "${YELLOW}|  [3/4] TASKS - Generating task breakdown                                     |${NC}"
    echo -e "${YELLOW}+------------------------------------------------------------------------------+${NC}"
    echo ""

    set_phase_status "$spec_num" "tasks" "in_progress"

    if run_speckit_command "speckit.tasks" ""; then
      set_phase_status "$spec_num" "tasks" "complete"
      echo -e "${GREEN}  [3/4] TASKS COMPLETE${NC}"
    else
      set_phase_status "$spec_num" "tasks" "failed"
      echo -e "${RED}  [3/4] TASKS FAILED${NC}"
      return 1
    fi
  else
    echo -e "${GREEN}  [3/4] tasks already complete, skipping${NC}"
  fi

  # Step 4: Implement (with inner loop)
  local implement_status=$(get_phase_status "$spec_num" "implement")
  if [[ "$implement_status" != "complete" ]]; then
    echo ""
    echo -e "${YELLOW}+------------------------------------------------------------------------------+${NC}"
    echo -e "${YELLOW}|  [4/4] IMPLEMENT - Executing tasks (will loop until complete)               |${NC}"
    echo -e "${YELLOW}+------------------------------------------------------------------------------+${NC}"
    echo ""

    set_phase_status "$spec_num" "implement" "in_progress"

    if run_implement_loop; then
      verify_migrations_applied
      set_phase_status "$spec_num" "implement" "complete"
      echo -e "${GREEN}  [4/4] IMPLEMENT COMPLETE - All tasks done!${NC}"
    else
      echo -e "${YELLOW}  [4/4] IMPLEMENT INCOMPLETE - Some tasks remain${NC}"
      verify_migrations_applied
      commit_spec_changes "$spec_num"
      echo ""
      echo -e "${YELLOW}+==============================================================================+${NC}"
      echo -e "${YELLOW}|  SPEC $spec_padded PAUSED: $title${NC}"
      echo -e "${YELLOW}|  Run the script again to continue where you left off                        |${NC}"
      echo -e "${YELLOW}+==============================================================================+${NC}"
      return 1
    fi
  else
    echo -e "${GREEN}  [4/4] implement already complete, skipping${NC}"
  fi

  mark_spec_complete_in_roadmap "$spec_num"
  commit_spec_changes "$spec_num"

  echo ""
  echo -e "${GREEN}+==============================================================================+${NC}"
  echo -e "${GREEN}|  SPEC $spec_padded COMPLETE: $title${NC}"
  echo -e "${GREEN}+==============================================================================+${NC}"
  echo ""
  return 0
}

# Alias for backward compatibility
run_phase_workflow() {
  run_spec_workflow "$1"
}

# -----------------------------------------------------------------------------
# MAIN
# -----------------------------------------------------------------------------

main() {
  clear
  echo ""
  echo -e "${CYAN}+==============================================================================+${NC}"
  echo -e "${CYAN}|                                                                              |${NC}"
  echo -e "${CYAN}|   SPECKIT AUTOMATION LOOP                                                   |${NC}"
  echo -e "${CYAN}|                                                                              |${NC}"
  echo -e "${CYAN}|   Automatically runs specify -> plan -> tasks -> implement for each spec   |${NC}"
  echo -e "${CYAN}|                                                                              |${NC}"
  echo -e "${CYAN}+==============================================================================+${NC}"
  echo ""
  echo -e "${BLUE}  Project:  $WORKDIR${NC}"
  echo -e "${BLUE}  Roadmap:  $ROADMAP_FILE${NC}"
  echo -e "${BLUE}  Started:  $(date '+%Y-%m-%d %H:%M:%S')${NC}"
  echo ""

  # Validate roadmap exists
  if [[ ! -f "$ROADMAP_FILE" ]]; then
    echo -e "${RED}  ERROR: Roadmap file not found: $ROADMAP_FILE${NC}"
    echo ""
    echo -e "${YELLOW}  Create an IMPLEMENTATION_ROADMAP.md file or specify the path:${NC}"
    echo -e "${YELLOW}    ROADMAP_FILE=/path/to/roadmap.md ./speckit-loop.sh${NC}"
    exit 1
  fi

  # Check for required tools
  if ! command -v jq &> /dev/null; then
    echo -e "${RED}  ERROR: jq is required but not installed.${NC}"
    echo -e "${YELLOW}  Install with: brew install jq (macOS) or apt install jq (Linux)${NC}"
    exit 1
  fi

  if ! command -v claude &> /dev/null; then
    echo -e "${RED}  ERROR: claude CLI is required but not installed.${NC}"
    echo -e "${YELLOW}  Install Claude Code CLI first.${NC}"
    exit 1
  fi

  # Setup
  setup_logging
  init_progress

  echo -e "${BLUE}  Log file: $LOGFILE${NC}"
  echo ""

  # Get all spec numbers
  local specs=$(get_spec_numbers)
  local total_specs=$(echo "$specs" | wc -l | tr -d ' ')

  echo -e "${GREEN}  Found $total_specs specs in roadmap${NC}"
  echo ""

  echo -e "${BLUE}  Specs to process:${NC}"
  for s in $specs; do
    local spec_padded=$(printf "%03d" "$s")
    local t=$(get_spec_title "$s")
    echo -e "     Spec $spec_padded: $t"
  done
  echo ""

  # Resume from last spec
  local start_spec=$(get_current_phase)
  if [[ "$start_spec" -gt 1 ]]; then
    local start_padded=$(printf "%03d" "$start_spec")
    echo -e "${YELLOW}  Resuming from Spec $start_padded (specs 001-$(printf "%03d" $((start_spec-1))) already complete)${NC}"
    echo ""
  fi

  echo -e "${CYAN}============================================================================${NC}"
  echo -e "${CYAN}  Press Ctrl+C to stop at any time. Progress is saved automatically.${NC}"
  echo -e "${CYAN}============================================================================${NC}"
  sleep 2

  # Process each spec
  local current=0
  for spec_num in $specs; do
    current=$((current + 1))
    local spec_padded=$(printf "%03d" "$spec_num")

    if [[ "$spec_num" -lt "$start_spec" ]]; then
      echo -e "${GREEN}  Spec $spec_padded already complete, skipping${NC}"
      continue
    fi

    set_current_phase "$spec_num"

    echo ""
    echo -e "${CYAN}+==============================================================================+${NC}"
    echo -e "${CYAN}|  STARTING SPEC $spec_padded OF $total_specs                                            ${NC}"
    echo -e "${CYAN}+==============================================================================+${NC}"

    if ! run_spec_workflow "$spec_num"; then
      echo ""
      echo -e "${RED}============================================================================${NC}"
      echo -e "${RED}  Spec $spec_padded failed. Stopping.${NC}"
      echo -e "${RED}  To retry, run: $0${NC}"
      echo -e "${RED}============================================================================${NC}"
      exit 1
    fi
  done

  echo ""
  echo -e "${GREEN}+==============================================================================+${NC}"
  echo -e "${GREEN}|                                                                              |${NC}"
  echo -e "${GREEN}|   ALL SPECS COMPLETE!                                                       |${NC}"
  echo -e "${GREEN}|                                                                              |${NC}"
  echo -e "${GREEN}+==============================================================================+${NC}"
  echo ""
  echo -e "${BLUE}  Full logs available at: $LOGFILE${NC}"
  echo -e "${BLUE}  Completed: $(date '+%Y-%m-%d %H:%M:%S')${NC}"
  echo ""
}

# Run main
main "$@"
