#!/usr/bin/env bash
# ==============================================================================
# Linux Server Health Monitoring Script
# Checks host telemetry, resources, services, and connectivity
# ==============================================================================

set -uo pipefail

# ------------------------------------------------------------------------------
# 1. Configurable Thresholds (%)
# ------------------------------------------------------------------------------
CPU_WARN_THRESHOLD=75
CPU_CRIT_THRESHOLD=90
MEM_WARN_THRESHOLD=80
MEM_CRIT_THRESHOLD=90
DISK_WARN_THRESHOLD=80
DISK_CRIT_THRESHOLD=90

SAVE_REPORT=false
REPORT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/reports"

# ------------------------------------------------------------------------------
# Parse Arguments
# ------------------------------------------------------------------------------
for arg in "$@"; do
    case "$arg" in
        -s|--save)
            SAVE_REPORT=true
            ;;
        -h|--help)
            echo "Usage: $(basename "$0") [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  -s, --save    Save report output to reports/ directory"
            echo "  -h, --help    Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $arg. Use --help for usage." >&2
            exit 1
            ;;
    esac
done

# ANSI Color formatting
if [[ -t 1 ]] && [[ "$SAVE_REPORT" == "false" ]]; then
    GREEN="\033[32m"
    YELLOW="\033[33m"
    RED="\033[31m"
    BLUE="\033[34m"
    BOLD="\033[1m"
    RESET="\033[0m"
else
    GREEN=""
    YELLOW=""
    RED=""
    BLUE=""
    BOLD=""
    RESET=""
fi

# ------------------------------------------------------------------------------
# 2. Metric Collection
# ------------------------------------------------------------------------------

# Hostname
HOSTNAME=$(hostname 2>/dev/null || uname -n)

# OS Version
if [[ -f /etc/os-release ]]; then
    OS_VERSION=$(grep "^PRETTY_NAME=" /etc/os-release | cut -d= -f2 | tr -d '"')
elif command -v lsb_release >/dev/null 2>&1; then
    OS_VERSION=$(lsb_release -ds)
else
    OS_VERSION="$(uname -s) $(uname -r)"
fi

# Uptime
if command -v uptime >/dev/null 2>&1; then
    UPTIME_VAL=$(uptime -p 2>/dev/null | sed 's/^up //' || uptime | awk -F'(up |,)' '{print $2}' | xargs)
else
    UPTIME_VAL="Unavailable"
fi

# CPU Usage
if [[ -f /proc/stat ]]; then
    read -r _ user nice sys idle iowait irq softirq steal _ < /proc/stat
    prev_idle=$((idle + iowait))
    prev_total=$((user + nice + sys + idle + iowait + irq + softirq + steal))

    sleep 0.3

    read -r _ user nice sys idle iowait irq softirq steal _ < /proc/stat
    cur_idle=$((idle + iowait))
    cur_total=$((user + nice + sys + idle + iowait + irq + softirq + steal))

    diff_idle=$((cur_idle - prev_idle))
    diff_total=$((cur_total - prev_total))

    if [[ "$diff_total" -gt 0 ]]; then
        CPU_USAGE=$(( (100 * (diff_total - diff_idle)) / diff_total ))
    else
        CPU_USAGE=0
    fi
else
    CPU_USAGE=$(top -bn1 2>/dev/null | grep "Cpu(s)" | awk '{print int($2 + $4)}' || echo 0)
fi

# Memory Usage
if command -v free >/dev/null 2>&1; then
    MEM_TOTAL=$(free -m | awk '/^Mem:/ {print $2}')
    MEM_AVAIL=$(free -m | awk '/^Mem:/ {print $7}')
    MEM_USED=$((MEM_TOTAL - MEM_AVAIL))
    if [[ "$MEM_TOTAL" -gt 0 ]]; then
        MEM_USAGE=$(( (MEM_USED * 100) / MEM_TOTAL ))
    else
        MEM_USAGE=0
    fi
    MEM_TOTAL_GB=$(awk -v m="$MEM_TOTAL" 'BEGIN { printf "%.1f", m/1024 }')
    MEM_USED_GB=$(awk -v m="$MEM_USED" 'BEGIN { printf "%.1f", m/1024 }')
else
    MEM_USAGE=0
    MEM_TOTAL_GB="0"
    MEM_USED_GB="0"
fi

# Disk Usage (Root partition /)
DISK_USAGE=$(df -h / 2>/dev/null | awk 'NR==2 {print $5}' | tr -d '%')
DISK_USED_HUMAN=$(df -h / 2>/dev/null | awk 'NR==2 {print $3}')
DISK_TOTAL_HUMAN=$(df -h / 2>/dev/null | awk 'NR==2 {print $2}')

# Running Processes Count
TOTAL_PROCESSES=$(ps -e 2>/dev/null | wc -l | xargs)

# Important Services Check
check_service() {
    local svc="$1"
    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-active --quiet "$svc" 2>/dev/null; then
            echo "RUNNING"
            return 0
        fi
    elif command -v service >/dev/null 2>&1; then
        if service "$svc" status >/dev/null 2>&1; then
            echo "RUNNING"
            return 0
        fi
    fi
    # Check if process is running directly
    if pgrep -f "$svc" >/dev/null 2>&1; then
        echo "RUNNING"
    else
        echo "STOPPED"
    fi
}

SSH_STATUS=$(check_service "sshd")
[[ "$SSH_STATUS" == "STOPPED" ]] && SSH_STATUS=$(check_service "ssh")

DOCKER_STATUS="NOT INSTALLED"
if command -v docker >/dev/null 2>&1; then
    DOCKER_STATUS=$(check_service "docker")
fi

# Network / Internet Connectivity Check
if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
    INTERNET_STATUS="OK"
elif command -v curl >/dev/null 2>&1 && curl -s --connect-timeout 2 -I https://www.google.com >/dev/null 2>&1; then
    INTERNET_STATUS="OK"
else
    INTERNET_STATUS="DISCONNECTED"
fi

# ------------------------------------------------------------------------------
# 3. Health Status Evaluation
# ------------------------------------------------------------------------------
OVERALL_STATUS="HEALTHY"

if [[ "$CPU_USAGE" -ge "$CPU_CRIT_THRESHOLD" ]] || \
   [[ "$MEM_USAGE" -ge "$MEM_CRIT_THRESHOLD" ]] || \
   [[ "$DISK_USAGE" -ge "$DISK_CRIT_THRESHOLD" ]] || \
   [[ "$SSH_STATUS" != "RUNNING" ]]; then
    OVERALL_STATUS="CRITICAL"
elif [[ "$CPU_USAGE" -ge "$CPU_WARN_THRESHOLD" ]] || \
     [[ "$MEM_USAGE" -ge "$MEM_WARN_THRESHOLD" ]] || \
     [[ "$DISK_USAGE" -ge "$DISK_WARN_THRESHOLD" ]] || \
     [[ "$INTERNET_STATUS" != "OK" ]]; then
    OVERALL_STATUS="WARNING"
fi

# ------------------------------------------------------------------------------
# 4. Generate & Display Report
# ------------------------------------------------------------------------------
generate_report() {
    cat <<EOF
===== SERVER HEALTH REPORT =====

Hostname       : ${HOSTNAME}
OS Version     : ${OS_VERSION}
Uptime         : ${UPTIME_VAL}
CPU Usage      : ${CPU_USAGE}%
Memory Usage   : ${MEM_USAGE}% (${MEM_USED_GB}GB / ${MEM_TOTAL_GB}GB)
Disk Usage     : ${DISK_USAGE}% (${DISK_USED_HUMAN} / ${DISK_TOTAL_HUMAN})
Processes      : ${TOTAL_PROCESSES} running

SSH Service    : ${SSH_STATUS}
Docker Service : ${DOCKER_STATUS}

Internet       : ${INTERNET_STATUS}

===== STATUS: ${OVERALL_STATUS} =====
EOF
}

# Print report to standard output
generate_report

# Save report if requested with -s or --save
if [[ "$SAVE_REPORT" == "true" ]]; then
    mkdir -p "$REPORT_DIR"
    REPORT_FILE="${REPORT_DIR}/health_report_$(date +'%Y%m%d_%H%M%S').txt"
    generate_report > "$REPORT_FILE"
    echo ""
    echo "Report saved to: $REPORT_FILE"
fi
