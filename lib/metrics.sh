#!/usr/bin/env bash
# ==============================================================================
# Linux Server Health Monitor - Metrics Extraction Engine
# Extracts CPU, Memory, Disk, Network, Process, Service and Security metrics
# ==============================================================================

if [[ -n "${_LIB_METRICS_LOADED:-}" ]]; then
    return 0
fi
_LIB_METRICS_LOADED=1

# Global data holders
CPU_CORES=1
CPU_USAGE=0
LOAD_1M="0.00"
LOAD_5M="0.00"
LOAD_15M="0.00"
LOAD_NORMALIZED="0.00"

MEM_TOTAL_MB=0
MEM_USED_MB=0
MEM_AVAIL_MB=0
MEM_USAGE_PCT=0
SWAP_TOTAL_MB=0
SWAP_USED_MB=0
SWAP_USAGE_PCT=0

declare -a DISK_METRICS=()
declare -a INODE_METRICS=()
declare -a TOP_CPU_PROCS=()
declare -a TOP_MEM_PROCS=()
declare -a SERVICE_STATUSES=()
declare -a OPEN_PORTS=()

ZOMBIE_COUNT=0
FAILED_SSH_COUNT=0
REBOOT_REQUIRED=false
SYSTEM_UPTIME="unknown"

# ------------------------------------------------------------------------------
# 1. CPU & Load Average Collector
# ------------------------------------------------------------------------------
collect_cpu_metrics() {
    log_message "DEBUG" "Collecting CPU and Load metrics..."
    
    # Core count
    if is_command_available nproc; then
        CPU_CORES=$(nproc)
    elif [[ -f /proc/cpuinfo ]]; then
        CPU_CORES=$(grep -c "^processor" /proc/cpuinfo 2>/dev/null || echo 1)
    fi
    [[ "$CPU_CORES" -le 0 ]] && CPU_CORES=1

    # Load Average
    if [[ -f /proc/loadavg ]]; then
        read -r LOAD_1M LOAD_5M LOAD_15M _ < /proc/loadavg
    else
        LOAD_1M=$(uptime | awk -F'load average:' '{ print $2 }' | cut -d, -f1 | tr -d ' ' || echo "0.00")
        LOAD_5M=$(uptime | awk -F'load average:' '{ print $2 }' | cut -d, -f2 | tr -d ' ' || echo "0.00")
        LOAD_15M=$(uptime | awk -F'load average:' '{ print $2 }' | cut -d, -f3 | tr -d ' ' || echo "0.00")
    fi

    # Core-normalized 1-minute load
    LOAD_NORMALIZED=$(awk -v l="$LOAD_1M" -v c="$CPU_CORES" 'BEGIN { printf "%.2f", l / c }' 2>/dev/null || echo "0.00")

    # CPU Utilization % using /proc/stat if available (instant 2-point delta sampling)
    if [[ -f /proc/stat ]]; then
        local prev_total prev_idle cur_total cur_idle
        read -r _ user nice sys idle iowait irq softirq steal _ < /proc/stat
        prev_idle=$((idle + iowait))
        prev_total=$((user + nice + sys + idle + iowait + irq + softirq + steal))

        sleep 0.2

        read -r _ user nice sys idle iowait irq softirq steal _ < /proc/stat
        cur_idle=$((idle + iowait))
        cur_total=$((user + nice + sys + idle + iowait + irq + softirq + steal))

        local diff_idle=$((cur_idle - prev_idle))
        local diff_total=$((cur_total - prev_total))

        if [[ "$diff_total" -gt 0 ]]; then
            CPU_USAGE=$(( (1000 * (diff_total - diff_idle) / diff_total + 5) / 10 ))
        else
            CPU_USAGE=0
        fi
    else
        # Fallback to top if /proc/stat is unreadable
        CPU_USAGE=$(top -bn1 2>/dev/null | grep "Cpu(s)" | awk '{print int($2 + $4)}' || echo 0)
    fi
}

# ------------------------------------------------------------------------------
# 2. Memory & Swap Collector (Buffer/Cache-aware)
# ------------------------------------------------------------------------------
collect_memory_metrics() {
    log_message "DEBUG" "Collecting Memory and Swap metrics..."

    if is_command_available free; then
        # Use free in megabytes
        local mem_line swap_line
        mem_line=$(free -m | awk '/^Mem:/ {print $2, $3, $7}')
        read -r MEM_TOTAL_MB MEM_USED_MB MEM_AVAIL_MB <<< "$mem_line"

        # Calculate actual percentage used: ((Total - Available) / Total) * 100
        if [[ "$MEM_TOTAL_MB" -gt 0 ]]; then
            MEM_USAGE_PCT=$(awk -v t="$MEM_TOTAL_MB" -v a="$MEM_AVAIL_MB" 'BEGIN { printf "%d", int(((t - a) / t) * 100) }' 2>/dev/null || echo 0)
        else
            MEM_USAGE_PCT=0
        fi

        swap_line=$(free -m | awk '/^Swap:/ {print $2, $3}')
        read -r SWAP_TOTAL_MB SWAP_USED_MB <<< "$swap_line"
        if [[ "$SWAP_TOTAL_MB" -gt 0 ]]; then
            SWAP_USAGE_PCT=$(awk -v t="$SWAP_TOTAL_MB" -v u="$SWAP_USED_MB" 'BEGIN { printf "%d", int((u / t) * 100) }' 2>/dev/null || echo 0)
        else
            SWAP_USAGE_PCT=0
        fi
    elif [[ -f /proc/meminfo ]]; then
        local mem_total mem_avail
        mem_total=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
        mem_avail=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
        MEM_TOTAL_MB=$((mem_total / 1024))
        MEM_AVAIL_MB=$((mem_avail / 1024))
        MEM_USED_MB=$((MEM_TOTAL_MB - MEM_AVAIL_MB))
        if [[ "$MEM_TOTAL_MB" -gt 0 ]]; then
            MEM_USAGE_PCT=$(( (MEM_USED_MB * 100) / MEM_TOTAL_MB ))
        fi
    fi
}

# ------------------------------------------------------------------------------
# 3. Disk Space & Inode Saturation Collector
# ------------------------------------------------------------------------------
collect_disk_metrics() {
    log_message "DEBUG" "Collecting Filesystem and Inode metrics..."
    DISK_METRICS=()
    INODE_METRICS=()

    # Space usage (POSIX format -P to prevent line breaks)
    while IFS= read -r line; do
        # Ignore non-storage devices (tmpfs, devtmpfs, udev)
        local fs size used avail pct mount
        read -r fs size used avail pct mount <<< "$line"
        if [[ "$fs" =~ ^/dev/ || "${CHECK_MOUNTS[*]}" =~ $mount ]]; then
            local clean_pct="${pct%\%}"
            DISK_METRICS+=("${mount}|${size}|${used}|${avail}|${clean_pct}")
        fi
    done < <(df -h -P 2>/dev/null | tail -n +2)

    # Inode saturation
    while IFS= read -r line; do
        local fs inodes iused ifree ipct mount
        read -r fs inodes iused ifree ipct mount <<< "$line"
        if [[ "$fs" =~ ^/dev/ || "${CHECK_MOUNTS[*]}" =~ $mount ]]; then
            local clean_ipct="${ipct%\%}"
            INODE_METRICS+=("${mount}|${inodes}|${iused}|${ifree}|${clean_ipct}")
        fi
    done < <(df -i -P 2>/dev/null | tail -n +2)
}

# ------------------------------------------------------------------------------
# 4. Top Resource Consuming Processes & Zombie Check
# ------------------------------------------------------------------------------
collect_process_metrics() {
    log_message "DEBUG" "Collecting Top Process metrics..."
    TOP_CPU_PROCS=()
    TOP_MEM_PROCS=()

    # Top 5 CPU processes: PID, USER, %CPU, %MEM, COMMAND
    while IFS= read -r line; do
        TOP_CPU_PROCS+=("$line")
    done < <(ps -eo pid,user,%cpu,%mem,comm --sort=-%cpu 2>/dev/null | head -n 6 | tail -n +2)

    # Top 5 Memory processes
    while IFS= read -r line; do
        TOP_MEM_PROCS+=("$line")
    done < <(ps -eo pid,user,%cpu,%mem,comm --sort=-%mem 2>/dev/null | head -n 6 | tail -n +2)

    # Count zombie processes (STAT 'Z')
    ZOMBIE_COUNT=$(ps -eo stat 2>/dev/null | awk '$1 ~ /Z/ {count++} END {print count+0}')
    [[ -z "$ZOMBIE_COUNT" ]] && ZOMBIE_COUNT=0
}

# ------------------------------------------------------------------------------
# 5. Critical Services & Network Listening Ports
# ------------------------------------------------------------------------------
collect_service_and_network_metrics() {
    log_message "DEBUG" "Collecting Service and Network Port metrics..."
    SERVICE_STATUSES=()
    OPEN_PORTS=()

    # Check designated services
    for svc in "${CHECK_SERVICES[@]}"; do
        local status="UNKNOWN"
        if is_command_available systemctl; then
            if systemctl is-active --quiet "$svc" 2>/dev/null; then
                status="ACTIVE"
            else
                status="INACTIVE"
            fi
        elif is_command_available service; then
            if service "$svc" status >/dev/null 2>&1; then
                status="ACTIVE"
            else
                status="INACTIVE"
            fi
        fi
        SERVICE_STATUSES+=("${svc}|${status}")
    done

    # Check network listening ports (ss or netstat)
    for port in "${CHECK_PORTS[@]}"; do
        local port_status="CLOSED"
        if is_command_available ss; then
            if ss -tuln 2>/dev/null | grep -q ":${port} "; then
                port_status="OPEN"
            fi
        elif is_command_available netstat; then
            if netstat -tuln 2>/dev/null | grep -q ":${port} "; then
                port_status="OPEN"
            fi
        fi
        OPEN_PORTS+=("${port}|${port_status}")
    done
}

# ------------------------------------------------------------------------------
# 6. Security, Uptime & Reboot Flag
# ------------------------------------------------------------------------------
collect_security_metrics() {
    log_message "DEBUG" "Collecting Security and Uptime metrics..."
    
    # Uptime
    if is_command_available uptime; then
        SYSTEM_UPTIME=$(uptime -p 2>/dev/null || uptime | awk -F'( |,|up )+' '{print $2, $3}' || echo "N/A")
    fi

    # Pending reboot flag
    if [[ -f /var/run/reboot-required ]]; then
        REBOOT_REQUIRED=true
    else
        REBOOT_REQUIRED=false
    fi

    # Failed SSH attempts in auth log (last 500 lines)
    local auth_log=""
    if [[ -f /var/log/auth.log ]]; then
        auth_log="/var/log/auth.log"
    elif [[ -f /var/log/secure ]]; then
        auth_log="/var/log/secure"
    fi

    if [[ -n "$auth_log" ]] && [[ -r "$auth_log" ]]; then
        FAILED_SSH_COUNT=$(tail -n 500 "$auth_log" 2>/dev/null | awk '/Failed password/ {count++} END {print count+0}')
    else
        FAILED_SSH_COUNT=0
    fi
    [[ -z "$FAILED_SSH_COUNT" ]] && FAILED_SSH_COUNT=0
}

# Master collection function
collect_all_metrics() {
    collect_cpu_metrics
    collect_memory_metrics
    collect_disk_metrics
    collect_process_metrics
    collect_service_and_network_metrics
    collect_security_metrics
}
