#!/usr/bin/env bash
# ==============================================================================
# Linux Server Health Monitor - Output & Reporting Library
# Generates CLI Terminal Dashboards, Structured JSON, and HTML Reports
# ==============================================================================

if [[ -n "${_LIB_REPORTER_LOADED:-}" ]]; then
    return 0
fi
_LIB_REPORTER_LOADED=1

# ------------------------------------------------------------------------------
# 1. Progress / Gauge Bar Utility
# ------------------------------------------------------------------------------
draw_progress_bar() {
    local pct="${1:-0}"
    local width=20
    local filled=$(( (pct * width) / 100 ))
    local empty=$(( width - filled ))
    [[ "$empty" -lt 0 ]] && empty=0

    local bar=""
    for ((i=0; i<filled; i++)); do bar+="#"; done
    for ((i=0; i<empty; i++)); do bar+="-"; done

    local color="$C_GREEN"
    [[ "$pct" -ge "${CPU_WARN_THRESHOLD:-75}" ]] && color="$C_YELLOW"
    [[ "$pct" -ge "${CPU_CRIT_THRESHOLD:-90}" ]] && color="$C_RED"

    echo -e "[${color}${bar}${C_RESET}] ${pct}%"
}

# ------------------------------------------------------------------------------
# 2. CLI Terminal Dashboard
# ------------------------------------------------------------------------------
render_cli_dashboard() {
    local status_badge="${C_GREEN}${C_BOLD}[ OK: HEALTHY ]${C_RESET}"
    [[ "$OVERALL_SYSTEM_STATUS" == "WARN" ]] && status_badge="${C_YELLOW}${C_BOLD}[ WARNING: ATTENTION REQUIRED ]${C_RESET}"
    [[ "$OVERALL_SYSTEM_STATUS" == "CRITICAL" ]] && status_badge="${C_BG_RED}${C_WHITE}${C_BOLD}[ CRITICAL: OUTAGE DETECTED ]${C_RESET}"

    echo ""
    echo -e "${C_CYAN}${C_BOLD}================================================================================${C_RESET}"
    echo -e "${C_BOLD} 📊 LINUX SERVER HEALTH MONITOR - TELEMETRY DASHBOARD${C_RESET}"
    echo -e "${C_CYAN}================================================================================${C_RESET}"
    echo -e " Hostname:    ${C_BOLD}${SERVER_NAME}${C_RESET} | Environment: ${C_BLUE}${ENVIRONMENT}${C_RESET} | Uptime: ${SYSTEM_UPTIME}"
    echo -e " Timestamp:   $(date '+%Y-%m-%d %H:%M:%S %Z') | System Status: ${status_badge}"
    echo -e "${C_CYAN}--------------------------------------------------------------------------------${C_RESET}"

    # CPU & System Load
    echo -e "${C_BOLD}⚙️  CPU & LOAD AVERAGES:${C_RESET}"
    echo -e "   Utilization:  $(draw_progress_bar "$CPU_USAGE") (${CPU_CORES} Cores available)"
    echo -e "   Load (1/5/15m): ${LOAD_1M} / ${LOAD_5M} / ${LOAD_15M} | Normalized Load (1m): ${LOAD_NORMALIZED}/core"
    echo ""

    # Memory & Swap
    echo -e "${C_BOLD}🧠 MEMORY & SWAP:${C_RESET}"
    echo -e "   RAM Used:     $(draw_progress_bar "$MEM_USAGE_PCT") (${MEM_USED_MB} MB used / ${MEM_TOTAL_MB} MB total, ${MEM_AVAIL_MB} MB avail)"
    if [[ "$SWAP_TOTAL_MB" -gt 0 ]]; then
        echo -e "   Swap Used:    $(draw_progress_bar "$SWAP_USAGE_PCT") (${SWAP_USED_MB} MB / ${SWAP_TOTAL_MB} MB)"
    else
        echo -e "   Swap Used:    Disabled / Not Configured"
    fi
    echo ""

    # Storage Partitions
    echo -e "${C_BOLD}💾 STORAGE & INODES:${C_RESET}"
    printf "   %-14s %-10s %-10s %-10s %-8s %-10s\n" "Mount" "Size" "Used" "Avail" "Space%" "Inodes%"
    for disk in "${DISK_METRICS[@]}"; do
        IFS='|' read -r mount size used avail pct <<< "$disk"
        local ipct="N/A"
        for inode in "${INODE_METRICS[@]}"; do
            if [[ "$inode" =~ ^${mount}\| ]]; then
                ipct="$(echo "$inode" | cut -d'|' -f5)%"
                break
            fi
        done
        local disk_color="$C_RESET"
        [[ "$pct" -ge "${DISK_WARN_THRESHOLD:-85}" ]] && disk_color="$C_YELLOW"
        [[ "$pct" -ge "${DISK_CRIT_THRESHOLD:-95}" ]] && disk_color="$C_RED"
        printf "   %-14s %-10s %-10s %-10s ${disk_color}%-8s${C_RESET} %-10s\n" "$mount" "$size" "$used" "$avail" "${pct}%" "$ipct"
    done
    echo ""

    # Critical Services
    echo -e "${C_BOLD}🛡️  MONITORED SERVICES:${C_RESET}"
    local svc_summary=""
    for svc_item in "${SERVICE_STATUSES[@]}"; do
        IFS='|' read -r svc status <<< "$svc_item"
        if [[ "$status" == "ACTIVE" ]]; then
            svc_summary+="${svc}: ${C_GREEN}[ACTIVE]${C_RESET}   "
        else
            svc_summary+="${svc}: ${C_RED}${C_BOLD}[DOWN]${C_RESET}   "
        fi
    done
    echo -e "   $svc_summary"
    echo ""

    # Top Resource Processes
    echo -e "${C_BOLD}🔥 TOP 3 CPU CONSUMING PROCESSES:${C_RESET}"
    printf "   %-8s %-12s %-8s %-8s %-20s\n" "PID" "USER" "%CPU" "%MEM" "COMMAND"
    local count=0
    for proc in "${TOP_CPU_PROCS[@]}"; do
        [[ $count -ge 3 ]] && break
        read -r pid user cpu mem comm <<< "$proc"
        printf "   %-8s %-12s %-8s %-8s %-20s\n" "$pid" "$user" "$cpu" "$mem" "$comm"
        ((count++))
    done
    echo ""

    # Active Incidents / Alerts
    if [[ ${#ACTIVE_ALERTS[@]} -gt 0 ]]; then
        echo -e "${C_RED}${C_BOLD}🚨 ACTIVE INCIDENTS & THRESHOLD BREACHES:${C_RESET}"
        for alert in "${ACTIVE_ALERTS[@]}"; do
            IFS=':' read -r key severity msg <<< "$alert"
            echo -e "   - ${C_BOLD}[${severity}]${C_RESET} ${msg}"
        done
    else
        echo -e "${C_GREEN}✅ All subsystems operating within baseline thresholds.${C_RESET}"
    fi
    echo -e "${C_CYAN}================================================================================${C_RESET}"
    echo ""
}

# ------------------------------------------------------------------------------
# 3. Structured JSON Telemetry Generator
# ------------------------------------------------------------------------------
render_json_output() {
    local timestamp
    timestamp="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

    cat <<EOF
{
  "timestamp": "${timestamp}",
  "server": {
    "hostname": "$(escape_json "$SERVER_NAME")",
    "environment": "$(escape_json "$ENVIRONMENT")",
    "uptime": "$(escape_json "$SYSTEM_UPTIME")",
    "reboot_required": ${REBOOT_REQUIRED}
  },
  "status": "${OVERALL_SYSTEM_STATUS}",
  "metrics": {
    "cpu": {
      "cores": ${CPU_CORES},
      "usage_percent": ${CPU_USAGE},
      "load_1m": ${LOAD_1M},
      "load_5m": ${LOAD_5M},
      "load_15m": ${LOAD_15M},
      "normalized_load": ${LOAD_NORMALIZED}
    },
    "memory": {
      "total_mb": ${MEM_TOTAL_MB},
      "used_mb": ${MEM_USED_MB},
      "available_mb": ${MEM_AVAIL_MB},
      "usage_percent": ${MEM_USAGE_PCT},
      "swap_used_mb": ${SWAP_USED_MB},
      "swap_total_mb": ${SWAP_TOTAL_MB},
      "swap_percent": ${SWAP_USAGE_PCT}
    },
    "security": {
      "failed_ssh_count": ${FAILED_SSH_COUNT},
      "zombie_processes": ${ZOMBIE_COUNT}
    }
  },
  "alerts_count": ${#ACTIVE_ALERTS[@]}
}
EOF
}

# ------------------------------------------------------------------------------
# 4. Standalone HTML Report Generator
# ------------------------------------------------------------------------------
render_html_report() {
    local target_file="${1:-$HTML_REPORT_PATH}"
    local target_dir
    target_dir="$(dirname "$target_file")"

    if [[ ! -d "$target_dir" ]]; then
        target_file="/tmp/server-health-report.html"
    fi

    local badge_color="#28a745"
    [[ "$OVERALL_SYSTEM_STATUS" == "WARN" ]] && badge_color="#ffc107"
    [[ "$OVERALL_SYSTEM_STATUS" == "CRITICAL" ]] && badge_color="#dc3545"

    cat <<EOF > "$target_file"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Server Health Report - ${SERVER_NAME}</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; background: #0f172a; color: #f8fafc; margin: 0; padding: 24px; }
        .container { max-width: 1000px; margin: 0 auto; }
        .header { display: flex; justify-content: space-between; align-items: center; border-bottom: 2px solid #334155; padding-bottom: 16px; margin-bottom: 24px; }
        .badge { background: ${badge_color}; color: #fff; padding: 6px 14px; border-radius: 9999px; font-weight: bold; font-size: 14px; }
        .grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 20px; margin-bottom: 24px; }
        .card { background: #1e293b; border: 1px solid #334155; border-radius: 8px; padding: 20px; box-shadow: 0 4px 6px -1px rgba(0,0,0,0.1); }
        .card-title { color: #94a3b8; font-size: 13px; text-transform: uppercase; letter-spacing: 0.05em; margin-bottom: 8px; font-weight: 600; }
        .metric-value { font-size: 28px; font-weight: 700; color: #fff; margin-bottom: 8px; }
        .progress-container { background: #334155; border-radius: 4px; height: 8px; width: 100%; overflow: hidden; margin-top: 8px; }
        .progress-fill { height: 100%; border-radius: 4px; }
        table { width: 100%; border-collapse: collapse; margin-top: 12px; font-size: 14px; }
        th, td { text-align: left; padding: 10px 12px; border-bottom: 1px solid #334155; }
        th { background: #334155; color: #cbd5e1; font-weight: 600; }
        .alert-box { background: #450a0a; border: 1px solid #dc2626; border-radius: 6px; padding: 14px; margin-bottom: 20px; color: #fecaca; }
    </style>
</head>
<body>
    <div class="container">
        <div class="header">
            <div>
                <h1 style="margin: 0; font-size: 24px;">Linux Server Telemetry</h1>
                <p style="margin: 4px 0 0 0; color: #94a3b8; font-size: 14px;">Host: <strong>${SERVER_NAME}</strong> (${ENVIRONMENT}) &bull; Uptime: ${SYSTEM_UPTIME}</p>
            </div>
            <div class="badge">${OVERALL_SYSTEM_STATUS}</div>
        </div>

        <div class="grid">
            <div class="card">
                <div class="card-title">CPU Utilization</div>
                <div class="metric-value">${CPU_USAGE}%</div>
                <div>Cores: ${CPU_CORES} | 1m Load: ${LOAD_1M}</div>
                <div class="progress-container">
                    <div class="progress-fill" style="width: ${CPU_USAGE}%; background: #38bdf8;"></div>
                </div>
            </div>

            <div class="card">
                <div class="card-title">Memory Saturation</div>
                <div class="metric-value">${MEM_USAGE_PCT}%</div>
                <div>${MEM_USED_MB} MB used / ${MEM_TOTAL_MB} MB total</div>
                <div class="progress-container">
                    <div class="progress-fill" style="width: ${MEM_USAGE_PCT}%; background: #34d399;"></div>
                </div>
            </div>

            <div class="card">
                <div class="card-title">System Health & Security</div>
                <div class="metric-value" style="font-size: 20px;">${ZOMBIE_COUNT} Zombies</div>
                <div>Failed SSH Logins: ${FAILED_SSH_COUNT}</div>
                <div>Reboot Required: ${REBOOT_REQUIRED}</div>
            </div>
        </div>

        <div class="card">
            <div class="card-title">Filesystem Partitions</div>
            <table>
                <thead>
                    <tr><th>Mount</th><th>Size</th><th>Used</th><th>Available</th><th>Capacity</th></tr>
                </thead>
                <tbody>
EOF

    for disk in "${DISK_METRICS[@]}"; do
        IFS='|' read -r mount size used avail pct <<< "$disk"
        cat <<EOF >> "$target_file"
                    <tr>
                        <td><strong>${mount}</strong></td>
                        <td>${size}</td>
                        <td>${used}</td>
                        <td>${avail}</td>
                        <td><strong>${pct}%</strong></td>
                    </tr>
EOF
    done

    cat <<EOF >> "$target_file"
                </tbody>
            </table>
        </div>
        <p style="color: #64748b; font-size: 12px; margin-top: 24px; text-align: center;">Report Generated by Linux Server Health Monitor &bull; $(date '+%Y-%m-%d %H:%M:%S %Z')</p>
    </div>
</body>
</html>
EOF
    log_message "INFO" "HTML telemetry report generated at: ${target_file}"
}
