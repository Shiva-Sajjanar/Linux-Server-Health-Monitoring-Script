#!/usr/bin/env bash
# ==============================================================================
# Linux Server Health Monitoring & Alerting Suite
# Main CLI Entrypoint & Orchestrator
# ==============================================================================

set -uo pipefail

VERSION="1.2.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Default configurations
CONFIG_FILE=""
OUTPUT_FORMAT="cli"
SILENT_MODE=false
TEST_ALERT=false

# ------------------------------------------------------------------------------
# Help / Usage Banner
# ------------------------------------------------------------------------------
show_help() {
    cat <<EOF
Linux Server Health Monitoring & Alerting Suite (v${VERSION})

Usage: $(basename "$0") [OPTIONS]

Options:
  -c, --config <PATH>    Path to custom configuration file (default: config/monitor.conf)
  -o, --output <FORMAT>  Telemetry output format: 'cli', 'json', or 'html' (default: cli)
  -s, --silent           Run in background/cron mode (suppresses terminal output, writes logs & alerts)
  -t, --test-alert       Send a synthetic test alert to verify webhook integration
  -v, --version          Show script version
  -h, --help             Display this help message

Examples:
  $(basename "$0")                        # Run interactive terminal dashboard
  $(basename "$0") -o json                # Output structured JSON metrics stream
  $(basename "$0") -o html                # Generate static HTML health report
  $(basename "$0") -s                     # Silent execution for cron/systemd
  $(basename "$0") -t                     # Test Slack/Discord webhook alerts

EOF
    exit 0
}

# ------------------------------------------------------------------------------
# Argument Parsing
# ------------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--config)
            CONFIG_FILE="$2"
            shift 2
            ;;
        -o|--output)
            OUTPUT_FORMAT="$2"
            shift 2
            ;;
        -s|--silent)
            SILENT_MODE=true
            shift
            ;;
        -t|--test-alert)
            TEST_ALERT=true
            shift
            ;;
        -v|--version)
            echo "Linux Server Health Monitor version ${VERSION}"
            exit 0
            ;;
        -h|--help)
            show_help
            ;;
        *)
            echo "Error: Unknown argument '$1'. Run with --help for options." >&2
            exit 1
            ;;
    esac
done

# ------------------------------------------------------------------------------
# Load Configuration
# ------------------------------------------------------------------------------
if [[ -z "$CONFIG_FILE" ]]; then
    if [[ -f "/etc/server-monitor/monitor.conf" ]]; then
        CONFIG_FILE="/etc/server-monitor/monitor.conf"
    elif [[ -f "${SCRIPT_DIR}/config/monitor.conf" ]]; then
        CONFIG_FILE="${SCRIPT_DIR}/config/monitor.conf"
    else
        echo "Error: Configuration file not found! Checked /etc/server-monitor/monitor.conf and ${SCRIPT_DIR}/config/monitor.conf" >&2
        exit 1
    fi
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"

# ------------------------------------------------------------------------------
# Load Libraries
# ------------------------------------------------------------------------------
LIB_DIR="${SCRIPT_DIR}/lib"
if [[ ! -d "$LIB_DIR" ]] && [[ -d "/usr/local/lib/server-monitor" ]]; then
    LIB_DIR="/usr/local/lib/server-monitor"
fi

# shellcheck source=lib/core.sh
source "${LIB_DIR}/core.sh"
# shellcheck source=lib/metrics.sh
source "${LIB_DIR}/metrics.sh"
# shellcheck source=lib/alerts.sh
source "${LIB_DIR}/alerts.sh"
# shellcheck source=lib/reporter.sh
source "${LIB_DIR}/reporter.sh"

# ------------------------------------------------------------------------------
# Handle Test Alert Flag
# ------------------------------------------------------------------------------
if [[ "$TEST_ALERT" == "true" ]]; then
    log_message "INFO" "Dispatching synthetic test incident to verify webhook..."
    send_webhook_notification "WARN" "TEST_PROBE" "This is a simulated health check probe from ${SERVER_NAME}."
    echo "Test probe dispatched to configured webhook (${WEBHOOK_URL:-None})."
    exit 0
fi

# ------------------------------------------------------------------------------
# Main Execution Cycle
# ------------------------------------------------------------------------------
acquire_lock

log_message "DEBUG" "Starting server telemetry sampling cycle..."

# Step 1: Collect all subsystems metrics
collect_all_metrics

# Step 2: Evaluate breaches against thresholds
evaluate_thresholds

# Step 3: Trigger alerts (with deduplication & cooldown)
dispatch_alerts

# Step 4: Render selected output
if [[ "$SILENT_MODE" != "true" ]]; then
    case "$OUTPUT_FORMAT" in
        cli)
            render_cli_dashboard
            ;;
        json)
            render_json_output
            ;;
        html)
            render_html_report
            ;;
        *)
            log_message "ERROR" "Unsupported output format '${OUTPUT_FORMAT}'. Defaulting to CLI dashboard."
            render_cli_dashboard
            ;;
    esac
fi

# Step 5: Exit with status code corresponding to server state
case "$OVERALL_SYSTEM_STATUS" in
    "OK")       exit 0 ;;
    "WARN")     exit 1 ;;
    "CRITICAL") exit 2 ;;
    *)          exit 0 ;;
esac
