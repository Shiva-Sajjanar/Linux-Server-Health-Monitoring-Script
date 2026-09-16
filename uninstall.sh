#!/usr/bin/env bash
# ==============================================================================
# Linux Server Health Monitor - Clean Uninstallation Script
# ==============================================================================

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Error: Uninstallation must be run as root (sudo ./uninstall.sh)" >&2
    exit 1
fi

echo "=== 1. Disabling and Removing Systemd Timers ==="
if command -v systemctl >/dev/null 2>&1; then
    systemctl stop server-monitor.timer 2>/dev/null || true
    systemctl disable server-monitor.timer 2>/dev/null || true
    rm -f /etc/systemd/system/server-monitor.service
    rm -f /etc/systemd/system/server-monitor.timer
    systemctl daemon-reload
fi

rm -f /etc/cron.d/server-monitor

echo "=== 2. Removing Binaries & Libraries ==="
rm -f /usr/local/bin/server-monitor
rm -rf /usr/local/lib/server-monitor

echo "=== 3. Cleaning Up Runtime Locks ==="
rm -f /tmp/server-monitor.lock /tmp/server-monitor.state
rm -f /var/run/server-monitor.lock /var/run/server-monitor.state

read -rp "Do you want to delete logs and configurations (/etc/server-monitor, /var/log/server-monitor)? [y/N]: " confirm
if [[ "$confirm" =~ ^[Yy]$ ]]; then
    rm -rf /etc/server-monitor
    rm -rf /var/log/server-monitor
    echo "Removed configurations and logs."
fi

echo "Uninstallation completed successfully."
