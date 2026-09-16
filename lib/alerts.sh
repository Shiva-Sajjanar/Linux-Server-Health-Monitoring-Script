#!/usr/bin/env bash
# ==============================================================================
# Linux Server Health Monitor - Alerting & Cooldown Engine
# Evaluates thresholds, handles state deduplication, and dispatches webhooks
# ==============================================================================

if [[ -n "${_LIB_ALERTS_LOADED:-}" ]]; then
    return 0
fi
_LIB_ALERTS_LOADED=1

declare -a ACTIVE_ALERTS=()
OVERALL_SYSTEM_STATUS="OK"  # OK, WARN, CRITICAL

# ------------------------------------------------------------------------------
# 1. State Tracking & Alert Cooldown Logic
# Prevents alert flooding; stores timestamps in STATE_FILE
# ------------------------------------------------------------------------------
should_suppress_alert() {
    local alert_key="$1"
    local current_severity="$2"
    local state_file="${STATE_FILE:-/tmp/server-monitor.state}"
    local cooldown_seconds=$(( ${ALERT_COOLDOWN_MINUTES:-30} * 60 ))
    local now
    now=$(date +%s)

    [[ ! -f "$state_file" ]] && touch "$state_file" 2>/dev/null || true

    # Format in state file: KEY|SEVERITY|TIMESTAMP
    local prev_record
    prev_record=$(grep "^${alert_key}|" "$state_file" 2>/dev/null || true)

    if [[ -n "$prev_record" ]]; then
        local prev_key prev_sev prev_time
        IFS='|' read -r prev_key prev_sev prev_time <<< "$prev_record"

        # If escalated from WARN to CRITICAL, do NOT suppress
        if [[ "$prev_sev" == "WARN" ]] && [[ "$current_severity" == "CRITICAL" ]]; then
            log_message "INFO" "Escalation detected for $alert_key (WARN -> CRITICAL). Triggering alert."
            update_alert_state "$alert_key" "$current_severity" "$now"
            return 1 # Do not suppress
        fi

        # Check if cooldown window is still active
        local elapsed=$((now - prev_time))
        if [[ "$elapsed" -lt "$cooldown_seconds" ]]; then
            log_message "DEBUG" "Alert for $alert_key is in cooldown ($elapsed/${cooldown_seconds}s). Suppressed."
            return 0 # Suppress
        fi
    fi

    update_alert_state "$alert_key" "$current_severity" "$now"
    return 1 # Do not suppress
}

update_alert_state() {
    local key="$1"
    local severity="$2"
    local timestamp="$3"
    local state_file="${STATE_FILE:-/tmp/server-monitor.state}"

    if [[ -w "$state_file" || -w "$(dirname "$state_file")" ]]; then
        # Remove old entry and append new
        grep -v "^${key}|" "$state_file" > "${state_file}.tmp" 2>/dev/null || true
        echo "${key}|${severity}|${timestamp}" >> "${state_file}.tmp"
        mv "${state_file}.tmp" "$state_file" 2>/dev/null || true
    fi
}

clear_recovered_alerts() {
    local state_file="${STATE_FILE:-/tmp/server-monitor.state}"
    if [[ ! -f "$state_file" ]]; then
        return 0
    fi

    # Read existing states; if an alert key is no longer in ACTIVE_ALERTS, send recovery notification
    while IFS='|' read -r key sev time; do
        [[ -z "$key" ]] && continue
        local still_active=false
        for alert in "${ACTIVE_ALERTS[@]}"; do
            if [[ "$alert" =~ ^${key}: ]]; then
                still_active=true
                break
            fi
        done

        if [[ "$still_active" == "false" ]]; then
            log_message "INFO" "Recovery detected for $key (was $sev). Sending resolution notice."
            dispatch_recovery_notification "$key"
            grep -v "^${key}|" "$state_file" > "${state_file}.tmp" 2>/dev/null || true
            mv "${state_file}.tmp" "$state_file" 2>/dev/null || true
        fi
    done < "$state_file"
}

# ------------------------------------------------------------------------------
# 2. Threshold Evaluation Engine
# ------------------------------------------------------------------------------
evaluate_thresholds() {
    log_message "DEBUG" "Evaluating system metrics against configured thresholds..."
    ACTIVE_ALERTS=()
    OVERALL_SYSTEM_STATUS="OK"

    # Evaluate CPU Utilization
    if [[ "$CPU_USAGE" -ge "${CPU_CRIT_THRESHOLD:-90}" ]]; then
        ACTIVE_ALERTS+=("CPU:CRITICAL:CPU usage is at ${CPU_USAGE}% (Threshold: ${CPU_CRIT_THRESHOLD}%)")
        OVERALL_SYSTEM_STATUS="CRITICAL"
    elif [[ "$CPU_USAGE" -ge "${CPU_WARN_THRESHOLD:-75}" ]]; then
        ACTIVE_ALERTS+=("CPU:WARN:CPU usage is elevated at ${CPU_USAGE}% (Threshold: ${CPU_WARN_THRESHOLD}%)")
        [[ "$OVERALL_SYSTEM_STATUS" != "CRITICAL" ]] && OVERALL_SYSTEM_STATUS="WARN"
    fi

    # Evaluate Load Average Multiplier
    local max_load_crit
    max_load_crit=$(awk -v c="$CPU_CORES" -v m="${LOAD_CRIT_MULTIPLIER:-2.5}" 'BEGIN { printf "%.2f", c * m }')
    local is_load_crit
    is_load_crit=$(awk -v l="$LOAD_1M" -v c="$max_load_crit" 'BEGIN { print (l >= c) ? 1 : 0 }')
    if [[ "$is_load_crit" -eq 1 ]]; then
        ACTIVE_ALERTS+=("LOAD:CRITICAL:1m Load Average is ${LOAD_1M} across ${CPU_CORES} cores (Critical Limit: ${max_load_crit})")
        OVERALL_SYSTEM_STATUS="CRITICAL"
    fi

    # Evaluate Memory Utilization
    if [[ "$MEM_USAGE_PCT" -ge "${MEM_CRIT_THRESHOLD:-92}" ]]; then
        ACTIVE_ALERTS+=("MEM:CRITICAL:RAM utilization is ${MEM_USAGE_PCT}% (${MEM_USED_MB}MB/${MEM_TOTAL_MB}MB)")
        OVERALL_SYSTEM_STATUS="CRITICAL"
    elif [[ "$MEM_USAGE_PCT" -ge "${MEM_WARN_THRESHOLD:-80}" ]]; then
        ACTIVE_ALERTS+=("MEM:WARN:RAM utilization is elevated at ${MEM_USAGE_PCT}%")
        [[ "$OVERALL_SYSTEM_STATUS" != "CRITICAL" ]] && OVERALL_SYSTEM_STATUS="WARN"
    fi

    # Evaluate Swap Utilization
    if [[ "$SWAP_TOTAL_MB" -gt 0 ]] && [[ "$SWAP_USAGE_PCT" -ge "${SWAP_CRIT_THRESHOLD:-80}" ]]; then
        ACTIVE_ALERTS+=("SWAP:CRITICAL:Swap memory is nearly exhausted at ${SWAP_USAGE_PCT}%")
        OVERALL_SYSTEM_STATUS="CRITICAL"
    fi

    # Evaluate Disk Storage
    for disk in "${DISK_METRICS[@]}"; do
        IFS='|' read -r mount size used avail pct <<< "$disk"
        if [[ "$pct" -ge "${DISK_CRIT_THRESHOLD:-95}" ]]; then
            ACTIVE_ALERTS+=("DISK_${mount}:CRITICAL:Partition ${mount} is at ${pct}% capacity (${used}/${size})")
            OVERALL_SYSTEM_STATUS="CRITICAL"
        elif [[ "$pct" -ge "${DISK_WARN_THRESHOLD:-85}" ]]; then
            ACTIVE_ALERTS+=("DISK_${mount}:WARN:Partition ${mount} is at ${pct}% capacity")
            [[ "$OVERALL_SYSTEM_STATUS" != "CRITICAL" ]] && OVERALL_SYSTEM_STATUS="WARN"
        fi
    done

    # Evaluate Inode Saturation
    for inode in "${INODE_METRICS[@]}"; do
        IFS='|' read -r mount inodes iused ifree ipct <<< "$inode"
        if [[ "$ipct" -ge "${INODE_CRIT_THRESHOLD:-95}" ]]; then
            ACTIVE_ALERTS+=("INODE_${mount}:CRITICAL:Inode saturation on ${mount} is ${ipct}%")
            OVERALL_SYSTEM_STATUS="CRITICAL"
        fi
    done

    # Evaluate Critical Services
    for svc_item in "${SERVICE_STATUSES[@]}"; do
        IFS='|' read -r svc status <<< "$svc_item"
        if [[ "$status" == "INACTIVE" ]]; then
            ACTIVE_ALERTS+=("SERVICE_${svc}:CRITICAL:Critical system service '${svc}' is DOWN or inactive!")
            OVERALL_SYSTEM_STATUS="CRITICAL"
        fi
    done

    # Evaluate Zombie Processes
    if [[ "$ZOMBIE_COUNT" -gt 0 ]]; then
        ACTIVE_ALERTS+=("ZOMBIES:WARN:Detected ${ZOMBIE_COUNT} zombie process(es) on host")
        [[ "$OVERALL_SYSTEM_STATUS" != "CRITICAL" ]] && OVERALL_SYSTEM_STATUS="WARN"
    fi

    # Evaluate Failed SSH Attempts
    if [[ "$FAILED_SSH_COUNT" -ge "${FAILED_SSH_THRESHOLD:-10}" ]]; then
        ACTIVE_ALERTS+=("SECURITY_SSH:WARN:${FAILED_SSH_COUNT} failed SSH authentication attempts detected")
        [[ "$OVERALL_SYSTEM_STATUS" != "CRITICAL" ]] && OVERALL_SYSTEM_STATUS="WARN"
    fi
}

# ------------------------------------------------------------------------------
# 3. Notification Dispatcher
# ------------------------------------------------------------------------------
dispatch_alerts() {
    clear_recovered_alerts

    if [[ ${#ACTIVE_ALERTS[@]} -eq 0 ]]; then
        log_message "DEBUG" "No active alerts to dispatch. System health is optimal."
        return 0
    fi

    for alert in "${ACTIVE_ALERTS[@]}"; do
        IFS=':' read -r key severity message <<< "$alert"

        # Check cooldown
        if should_suppress_alert "$key" "$severity"; then
            continue
        fi

        log_message "$severity" "INCIDENT TRIGGERED: [$severity] $message"

        # Dispatch via Syslog
        if [[ "${ENABLE_SYSLOG:-true}" == "true" ]] && is_command_available logger; then
            logger -t "server-monitor" -p "daemon.warning" "[$severity] [${SERVER_NAME}] $message"
        fi

        # Dispatch via Webhook
        if [[ "${ENABLE_WEBHOOK:-false}" == "true" ]] && [[ -n "${WEBHOOK_URL:-}" ]]; then
            send_webhook_notification "$severity" "$key" "$message"
        fi
    done
}

send_webhook_notification() {
    local severity="$1"
    local key="$2"
    local message="$3"
    local webhook_type="${WEBHOOK_TYPE:-slack}"

    local color="#36a64f" # green
    [[ "$severity" == "WARN" ]] && color="#f2c744"     # yellow
    [[ "$severity" == "CRITICAL" ]] && color="#d9534f" # red

    local payload=""
    if [[ "$webhook_type" == "slack" ]]; then
        payload=$(cat <<EOF
{
  "attachments": [
    {
      "color": "${color}",
      "title": "🚨 [${severity}] Server Incident: ${SERVER_NAME}",
      "fields": [
        {"title": "Environment", "value": "${ENVIRONMENT}", "short": true},
        {"title": "Severity", "value": "${severity}", "short": true},
        {"title": "Component", "value": "${key}", "short": true},
        {"title": "Details", "value": "${message}", "short": false}
      ],
      "footer": "Linux Server Health Monitor",
      "ts": $(date +%s)
    }
  ]
}
EOF
)
    elif [[ "$webhook_type" == "discord" ]]; then
        local decimal_color=3581519 # green
        [[ "$severity" == "WARN" ]] && decimal_color=15911236
        [[ "$severity" == "CRITICAL" ]] && decimal_color=14242639
        payload=$(cat <<EOF
{
  "embeds": [
    {
      "title": "🚨 [${severity}] Server Incident Alert",
      "color": ${decimal_color},
      "description": "**Server:** ${SERVER_NAME} (${ENVIRONMENT})\n**Component:** ${key}\n**Details:** ${message}",
      "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    }
  ]
}
EOF
)
    else
        # Generic JSON
        payload="{\"server\":\"${SERVER_NAME}\",\"severity\":\"${severity}\",\"key\":\"${key}\",\"message\":\"${message}\",\"timestamp\":\"$(date '+%Y-%m-%d %H:%M:%S')\"}"
    fi

    # Dispatch asynchronously using curl
    if is_command_available curl; then
        curl -s -X POST -H 'Content-type: application/json' --data "$payload" "$WEBHOOK_URL" >/dev/null 2>&1 || true
    fi
}

dispatch_recovery_notification() {
    local key="$1"
    if [[ "${ENABLE_WEBHOOK:-false}" != "true" ]] || [[ -z "${WEBHOOK_URL:-}" ]]; then
        return 0
    fi

    local payload
    payload=$(cat <<EOF
{
  "attachments": [
    {
      "color": "#36a64f",
      "title": "✅ [RESOLVED] Component Recovered: ${SERVER_NAME}",
      "text": "Component *${key}* has returned to normal operating parameters.",
      "footer": "Linux Server Health Monitor",
      "ts": $(date +%s)
    }
  ]
}
EOF
)
    if is_command_available curl; then
        curl -s -X POST -H 'Content-type: application/json' --data "$payload" "$WEBHOOK_URL" >/dev/null 2>&1 || true
    fi
}
