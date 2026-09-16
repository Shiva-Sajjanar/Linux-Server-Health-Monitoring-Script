#!/usr/bin/env bash
# ==============================================================================
# Linux Server Health Monitor - Core Utilities Library
# Handles logging, process locking, signal handling, and ANSI styling
# ==============================================================================

# Ensure script halts if imported incorrectly
if [[ -n "${_LIB_CORE_LOADED:-}" ]]; then
    return 0
fi
_LIB_CORE_LOADED=1

# ANSI Color Codes (Auto-disabled if not interactive terminal)
if [[ -t 1 ]] && [[ "${NO_COLOR:-}" != "1" ]]; then
    C_RESET="\033[0m"
    C_BOLD="\033[1m"
    C_DIM="\033[2m"
    C_RED="\033[31m"
    C_GREEN="\033[32m"
    C_YELLOW="\033[33m"
    C_BLUE="\033[34m"
    C_MAGENTA="\033[35m"
    C_CYAN="\033[36m"
    C_WHITE="\033[37m"
    C_BG_RED="\033[41m"
    C_BG_YELLOW="\033[43m"
else
    C_RESET=""
    C_BOLD=""
    C_DIM=""
    C_RED=""
    C_GREEN=""
    C_YELLOW=""
    C_BLUE=""
    C_MAGENTA=""
    C_CYAN=""
    C_WHITE=""
    C_BG_RED=""
    C_BG_YELLOW=""
fi

# Log levels enumeration
declare -A LOG_LEVELS=( ["DEBUG"]=0 ["INFO"]=1 ["WARN"]=2 ["ERROR"]=3 ["CRITICAL"]=4 )

# ------------------------------------------------------------------------------
# Logging Function
# Writes timestamped, leveled logs to standard streams and the configured logfile
# ------------------------------------------------------------------------------
log_message() {
    local level="${1:-INFO}"
    shift
    local msg="$*"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"

    local configured_level="${LOG_LEVEL:-INFO}"
    local level_num="${LOG_LEVELS[$level]:-1}"
    local conf_num="${LOG_LEVELS[$configured_level]:-1}"

    # Filter messages below the configured log level
    if [[ "$level_num" -lt "$conf_num" ]]; then
        return 0
    fi

    local color_prefix=""
    case "$level" in
        "DEBUG")    color_prefix="${C_DIM}[DEBUG]${C_RESET}" ;;
        "INFO")     color_prefix="${C_GREEN}[INFO]${C_RESET}" ;;
        "WARN")     color_prefix="${C_YELLOW}[WARN]${C_RESET}" ;;
        "ERROR")    color_prefix="${C_RED}[ERROR]${C_RESET}" ;;
        "CRITICAL") color_prefix="${C_BG_RED}${C_WHITE}${C_BOLD}[CRITICAL]${C_RESET}" ;;
    esac

    # Print to console if not running in silent/cron mode
    if [[ "${SILENT_MODE:-false}" != "true" ]]; then
        echo -e "${C_DIM}${timestamp}${C_RESET} ${color_prefix} ${msg}" >&2
    fi

    # Write to log file if directory is accessible
    if [[ -n "${LOG_FILE:-}" ]]; then
        local log_dir
        log_dir="$(dirname "$LOG_FILE")"
        if [[ -d "$log_dir" ]] && [[ -w "$log_dir" || -w "$LOG_FILE" ]]; then
            echo "[${timestamp}] [${level}] ${msg}" >> "$LOG_FILE" 2>/dev/null || true
        fi
    fi
}

# ------------------------------------------------------------------------------
# Process Concurrency Lock (Prevents overlapping cron/systemd executions)
# ------------------------------------------------------------------------------
acquire_lock() {
    local lockfile="${LOCK_FILE:-/tmp/server-monitor.lock}"
    local lock_dir
    lock_dir="$(dirname "$lockfile")"

    if [[ ! -d "$lock_dir" ]] || [[ ! -w "$lock_dir" ]]; then
        lockfile="/tmp/server-monitor.lock"
    fi

    if command -v flock >/dev/null 2>&1; then
        exec 200>"$lockfile"
        if ! flock -n 200; then
            log_message "WARN" "Another instance of server-monitor is currently executing (Lockfile: $lockfile). Exiting safely."
            exit 0
        fi
    else
        # Fallback PID check
        if [[ -f "$lockfile" ]]; then
            local pid
            pid="$(cat "$lockfile" 2>/dev/null || true)"
            if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
                log_message "WARN" "Active process ($pid) detected in $lockfile. Exiting."
                exit 0
            fi
        fi
        echo "$$" > "$lockfile"
    fi
}

release_lock() {
    local lockfile="${LOCK_FILE:-/tmp/server-monitor.lock}"
    if [[ -f "$lockfile" ]]; then
        rm -f "$lockfile" 2>/dev/null || true
    fi
}

# ------------------------------------------------------------------------------
# Signal Trap & Cleanup Handler
# ------------------------------------------------------------------------------
cleanup() {
    local exit_code=$?
    log_message "DEBUG" "Cleaning up runtime resources (Exit Code: $exit_code)..."
    release_lock
    exit "$exit_code"
}

trap cleanup EXIT INT TERM

# ------------------------------------------------------------------------------
# Helper Utilities
# ------------------------------------------------------------------------------
is_command_available() {
    command -v "$1" >/dev/null 2>&1
}

escape_json() {
    local string="$1"
    string="${string//\\/\\\\}"
    string="${string//\"/\\\"}"
    string="${string//$'\n'/\\n}"
    string="${string//$'\r'/\\r}"
    string="${string//$'\t'/\\t}"
    echo -n "$string"
}
