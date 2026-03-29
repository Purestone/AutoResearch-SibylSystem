#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# Sibyl Sentinel - Watchdog for opencode experiment resilience
# ═══════════════════════════════════════════════════════════════
#
# Runs in a sibling tmux pane, monitors experiment state and
# opencode process health. Automatically revives opencode when
# it stops unexpectedly while experiments are still active.
#
# Usage:
#   bash sibyl/sentinel.sh <workspace_path> <tmux_pane> [poll_interval_sec]
#
# Arguments:
#   workspace_path    e.g. workspaces/ttt-dlm (relative or absolute)
#   tmux_pane         e.g. sibyl:0.0 (target pane where opencode runs)
#   poll_interval_sec default 120 (2 minutes)
#
# Stop: echo '{"stop":true}' > <workspace>/sentinel_stop.json
# ═══════════════════════════════════════════════════════════════

set -euo pipefail

SIBYL_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKSPACE="${1:?Usage: sentinel.sh <workspace_path> <tmux_pane> [interval_sec]}"
TMUX_PANE="${2:?Usage: sentinel.sh <workspace_path> <tmux_pane> [interval_sec]}"
POLL_INTERVAL="${3:-120}"
PYTHON="$SIBYL_ROOT/.venv/bin/python3"

# Resolve workspace to absolute path
if [[ ! "$WORKSPACE" = /* ]]; then
    WORKSPACE="$SIBYL_ROOT/$WORKSPACE"
fi

HEARTBEAT_FILE="$WORKSPACE/sentinel_heartbeat.json"
SESSION_FILE="$WORKSPACE/sentinel_session.json"
STOP_FILE="$WORKSPACE/sentinel_stop.json"
STALE_THRESHOLD=300  # 5 minutes
SENTINEL_CONFIG='{}'
PROJECT_NAME="$(basename "$WORKSPACE")"

# Consecutive wake attempts before backing off
MAX_WAKE_ATTEMPTS=3
wake_attempts=0

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] SENTINEL: $*"
}

# ─── Process detection ────────────────────────────────────────

# Get the PID of the shell running in the target tmux pane
get_pane_shell_pid() {
    tmux display-message -t "$TMUX_PANE" -p '#{pane_pid}' 2>/dev/null || echo ""
}

# Check if opencode process is running in the target tmux pane
opencode_is_running() {
    local pane_pid
    pane_pid=$(get_pane_shell_pid)
    [[ -n "$pane_pid" ]] || return 1
    pgrep -P "$pane_pid" -f "opencode" >/dev/null 2>&1
}

# Check if opencode has active child processes (bash commands, sleep, ssh, etc.)
# This prevents false "idle" detection when opencode is running a tool like
# `bash sleep 600` during experiment_wait polling.
opencode_has_active_children() {
    local pane_pid opencode_pid
    pane_pid=$(get_pane_shell_pid)
    [[ -n "$pane_pid" ]] || return 1

    # Find opencode's PID (direct child of pane shell)
    opencode_pid=$(pgrep -P "$pane_pid" -f "opencode" 2>/dev/null | head -1)
    [[ -n "$opencode_pid" ]] || return 1

    # Check if opencode has any child processes (tool execution in progress)
    # Common children: bash, sleep, ssh, python3, node
    local children
    children=$(pgrep -P "$opencode_pid" 2>/dev/null | wc -l | tr -d ' ')
    [[ "$children" -gt 0 ]]
}

# ─── State checks (pure file reads, no LLM) ──────────────────

read_sentinel_config() {
    SIBYL_WORKSPACE="$WORKSPACE" "$PYTHON" - <<'PY'
import os
from sibyl.orchestrate import cli_sentinel_config

cli_sentinel_config(os.environ["SIBYL_WORKSPACE"])
PY
}

refresh_sentinel_config() {
    local config_output
    config_output=$(read_sentinel_config 2>/dev/null) || return 1
    if ! echo "$config_output" | jq -e . >/dev/null 2>&1; then
        return 1
    fi
    SENTINEL_CONFIG="$config_output"
    PROJECT_NAME=$(echo "$SENTINEL_CONFIG" | jq -r '.project_name // ""' 2>/dev/null)
    if [[ -z "$PROJECT_NAME" || "$PROJECT_NAME" == "null" ]]; then
        PROJECT_NAME="$(basename "$WORKSPACE")"
    fi
    CONTINUE_TARGET=$(echo "$SENTINEL_CONFIG" | jq -r '.workspace_path // ""' 2>/dev/null)
    if [[ -z "$CONTINUE_TARGET" || "$CONTINUE_TARGET" == "null" ]]; then
        CONTINUE_TARGET="$WORKSPACE"
    fi
    return 0
}

# Check if heartbeat is stale (older than STALE_THRESHOLD seconds)
heartbeat_stale() {
    if [[ ! -f "$HEARTBEAT_FILE" ]]; then
        return 0  # No heartbeat file = stale
    fi
    local ts now diff
    ts=$(jq -r '.ts' "$HEARTBEAT_FILE" 2>/dev/null) || return 0
    now=$(date +%s)
    # Handle float timestamps (truncate to int)
    diff=$((now - ${ts%%.*}))
    [[ $diff -gt $STALE_THRESHOLD ]]
}

# Get saved session ID for --resume
get_session_id() {
    local session_id=""
    session_id=$(echo "$SENTINEL_CONFIG" | jq -r '.session_id // ""' 2>/dev/null || echo "")
    if [[ -n "$session_id" ]]; then
        echo "$session_id"
        return
    fi
    if [[ -f "$SESSION_FILE" ]]; then
        jq -r '.session_id // ""' "$SESSION_FILE" 2>/dev/null || echo ""
    else
        echo ""
    fi
}

# ─── Actions ──────────────────────────────────────────────────

# Restart opencode in the target pane (Case A: process dead)
restart_opencode() {
    local session_id
    session_id=$(get_session_id)

    log "RESTART: opencode process not found, restarting..."

    if [[ -n "$session_id" ]]; then
        log "  Resuming session: ${session_id:0:12}..."
        # Use `opencode resume <session_id>` to restore the previous session
        tmux send-keys -t "$TMUX_PANE" "cd $SIBYL_ROOT && opencode resume $session_id" Enter
    else
        log "  No session ID, starting fresh opencode session"
        tmux send-keys -t "$TMUX_PANE" "cd $SIBYL_ROOT && opencode" Enter
    fi

    # Wait for opencode to start (up to 90 seconds)
    local waited=0
    while ! opencode_is_running && [[ $waited -lt 90 ]]; do
        sleep 5
        waited=$((waited + 5))
        log "  Waiting for opencode to start... (${waited}s)"
    done

    if opencode_is_running; then
        log "  opencode started. Waiting 15s for initialization..."
        sleep 15
        # Inject resume command
        tmux send-keys -t "$TMUX_PANE" "/sibyl-research:continue $CONTINUE_TARGET" Enter
        log "  Injected /sibyl-research:continue $PROJECT_NAME"
        wake_attempts=0
    else
        log "  ERROR: opencode failed to start after 90s"
        wake_attempts=$((wake_attempts + 1))
    fi
}

# Wake up an idle opencode session (Case B: process alive but stale heartbeat)
wake_opencode() {
    log "WAKE: Heartbeat stale, nudging opencode..."
    tmux send-keys -t "$TMUX_PANE" "/sibyl-research:continue $CONTINUE_TARGET" Enter
    log "  Injected /sibyl-research:continue $PROJECT_NAME"
    wake_attempts=$((wake_attempts + 1))
}

# ═══════════════════════════════════════════════════════════════
# Main loop
# ═══════════════════════════════════════════════════════════════

log "╔═══════════════════════════════════════╗"
log "║  SIBYL SENTINEL - Watchdog Active     ║"
log "╚═══════════════════════════════════════╝"
log "  Workspace:  $WORKSPACE"
log "  Target:     $TMUX_PANE"
log "  Interval:   ${POLL_INTERVAL}s"
log "  Stale:      ${STALE_THRESHOLD}s"
log ""

while true; do
    # ── Check stop signal ──
    if [[ -f "$STOP_FILE" ]]; then
        log "Stop signal received. Goodbye."
        rm -f "$STOP_FILE"
        exit 0
    fi

    if ! refresh_sentinel_config; then
        log "warning - failed to read sentinel config"
        sleep "$POLL_INTERVAL"
        continue
    fi

    if [[ "$(echo "$SENTINEL_CONFIG" | jq -r '.watchdog_allowed // false')" != "true" ]]; then
        log "ownership conflict detected; watchdog exiting for safety"
        log "  Conflicts: $(echo "$SENTINEL_CONFIG" | jq -c '.conflicts // []')"
        exit 0
    fi

    # ── Check if project is active ──
    if [[ "$(echo "$SENTINEL_CONFIG" | jq -r '.should_keep_running // false')" != "true" ]]; then
        log "idle - no active work"
        wake_attempts=0
        sleep "$POLL_INTERVAL"
        continue
    fi

    # ── Back-off: too many consecutive wake attempts ──
    if [[ $wake_attempts -ge $MAX_WAKE_ATTEMPTS ]]; then
        backoff=$((POLL_INTERVAL * 3))
        log "BACKOFF: $wake_attempts consecutive attempts failed, sleeping ${backoff}s"
        sleep "$backoff"
        wake_attempts=0
        continue
    fi

    # ── Case A: opencode process is dead ──
    if ! opencode_is_running; then
        log "opencode NOT running! Confirming in 5s..."
        sleep 5
        if ! opencode_is_running; then
            restart_opencode
            sleep "$POLL_INTERVAL"
            continue
        fi
    fi

    # ── opencode is running ──

    # Check for active children (bash/sleep/ssh tool execution)
    if opencode_has_active_children; then
        log "ok - opencode running, tool executing (has children)"
        wake_attempts=0
        sleep "$POLL_INTERVAL"
        continue
    fi

    # No active children - check heartbeat freshness
    if heartbeat_stale; then
        log "opencode running but heartbeat stale, no active tools"
        wake_opencode
    else
        log "ok - opencode running, heartbeat fresh"
        wake_attempts=0
    fi

    sleep "$POLL_INTERVAL"
done
