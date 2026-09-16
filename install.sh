#!/usr/bin/env bash
# ==============================================================================
# Linux Server Health Monitor - Automated Production Installer
# Installs binaries, libraries, configuration, and systemd timers
# ==============================================================================

set -euo pipefail

# Ensure running with administrative privileges
if [[ $EUID -ne 0 ]]; then
    echo "Error: This installer must be executed with root privileges (e.g. sudo ./install.sh)" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== 1. Creating System Directories ==="
mkdir -p /etc/server-monitor
mkdir -p /usr/local/lib/server-monitor
mkdir -p /var/log/server-monitor
mkdir -p /var/run

echo "=== 2. Installing Libraries & Executable ==="
cp -r "${SCRIPT_DIR}/lib/"* /usr/local/lib/server-monitor/
chmod 644 /usr/local/lib/server-monitor/*.sh

cp "${SCRIPT_DIR}/bin/monitor.sh" /usr/local/bin/server-monitor
chmod 755 /usr/local/bin/server-monitor

echo "=== 3. Setting Up Configuration File ==="
if [[ ! -f /etc/server-monitor/monitor.conf ]]; then
    cp "${SCRIPT_DIR}/config/monitor.conf" /etc/server-monitor/monitor.conf
    chmod 600 /etc/server-monitor/monitor.conf
    echo "Default configuration copied to /etc/server-monitor/monitor.conf"
else
    echo "Existing configuration preserved at /etc/server-monitor/monitor.conf"
fi

echo "=== 4. Configuring Systemd Automation ==="
if command -v systemctl >/dev/null 2>&1; then
    cp "${SCRIPT_DIR}/systemd/server-monitor.service" /etc/systemd/system/
    cp "${SCRIPT_DIR}/systemd/server-monitor.timer" /etc/systemd/system/
    
    systemctl daemon-reload
    systemctl enable --now server-monitor.timer
    echo "Systemd timer activated: checking every 5 minutes."
elif [[ -d /etc/cron.d ]]; then
    cp "${SCRIPT_DIR}/cron/server-monitor.cron" /etc/cron.d/server-monitor
    chmod 644 /etc/cron.d/server-monitor
    echo "Cron job installed to /etc/cron.d/server-monitor."
fi

echo ""
echo "================================================================================"
echo " Installation Complete!"
echo " - Run manually anytime with:    server-monitor"
echo " - View JSON stream with:       server-monitor -o json"
echo " - Generate HTML report with:   server-monitor -o html"
echo " - Configuration file:          /etc/server-monitor/monitor.conf"
echo " - Log file:                    /var/log/server-monitor/monitor.log"
echo "================================================================================"
