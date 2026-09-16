#!/usr/bin/env bash
# ==============================================================================
# Linux Server Health Monitor - Automated Test Suite
# Runs syntax validation, unit tests, and threshold mock evaluations
# ==============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TESTS_PASSED=0
TESTS_FAILED=0

# Formatting
RED="\033[31m"
GREEN="\033[32m"
BOLD="\033[1m"
RESET="\033[0m"

pass() {
    echo -e "${GREEN}${BOLD}[ PASS ]${RESET} $1"
    ((TESTS_PASSED++))
}

fail() {
    echo -e "${RED}${BOLD}[ FAIL ]${RESET} $1"
    ((TESTS_FAILED++))
}

echo "================================================================================"
echo " Running Automated Unit & Integration Tests for Server Health Monitor"
echo "================================================================================"

# ------------------------------------------------------------------------------
# Test 1: Bash Syntax Validation (bash -n)
# ------------------------------------------------------------------------------
echo "--- 1. Testing Bash Syntax ---"
for file in "${SCRIPT_DIR}/bin/monitor.sh" "${SCRIPT_DIR}/lib/"*.sh "${SCRIPT_DIR}/install.sh" "${SCRIPT_DIR}/uninstall.sh"; do
    if bash -n "$file"; then
        pass "Syntax check: $(basename "$file")"
    else
        fail "Syntax error in: $file"
    fi
done

# ------------------------------------------------------------------------------
# Test 2: Configuration Sourcing
# ------------------------------------------------------------------------------
echo "--- 2. Testing Configuration Integrity ---"
if [[ -f "${SCRIPT_DIR}/config/monitor.conf" ]]; then
    # shellcheck source=/dev/null
    source "${SCRIPT_DIR}/config/monitor.conf"
    if [[ -n "${CPU_WARN_THRESHOLD:-}" ]] && [[ -n "${MEM_CRIT_THRESHOLD:-}" ]]; then
        pass "Configuration loaded successfully with expected threshold variables."
    else
        fail "Configuration missing critical threshold variables."
    fi
else
    fail "Default configuration file not found!"
fi

# ------------------------------------------------------------------------------
# Test 3: Core Utility Functions
# ------------------------------------------------------------------------------
echo "--- 3. Testing Core Libraries ---"
# shellcheck source=lib/core.sh
source "${SCRIPT_DIR}/lib/core.sh"

# Test JSON escaping
raw_str="line 1
line 2 with \"quotes\" and \\slash"
escaped_str=$(escape_json "$raw_str")
if [[ "$escaped_str" =~ \\n && "$escaped_str" =~ \\\" ]]; then
    pass "escape_json properly sanitized newlines and quotes."
else
    fail "escape_json failed to escape characters."
fi

# ------------------------------------------------------------------------------
# Test 4: Threshold Evaluation Logic
# ------------------------------------------------------------------------------
echo "--- 4. Testing Threshold Alert Logic ---"
# shellcheck source=lib/alerts.sh
source "${SCRIPT_DIR}/lib/alerts.sh"

# Mock metrics
CPU_USAGE=95
CPU_CRIT_THRESHOLD=90
MEM_USAGE_PCT=50
MEM_CRIT_THRESHOLD=92
LOAD_1M="0.50"
CPU_CORES=4
LOAD_CRIT_MULTIPLIER="2.5"
SWAP_TOTAL_MB=0
DISK_METRICS=()
INODE_METRICS=()
SERVICE_STATUSES=()
ZOMBIE_COUNT=0
FAILED_SSH_COUNT=0

evaluate_thresholds
if [[ "$OVERALL_SYSTEM_STATUS" == "CRITICAL" ]]; then
    pass "Threshold engine correctly flagged 95% CPU as CRITICAL."
else
    fail "Threshold engine did not trigger CRITICAL for 95% CPU."
fi

# Mock healthy state
CPU_USAGE=30
MEM_USAGE_PCT=40
evaluate_thresholds
if [[ "$OVERALL_SYSTEM_STATUS" == "OK" ]]; then
    pass "Threshold engine correctly evaluated healthy metrics as OK."
else
    fail "Threshold engine triggered false alarm on healthy metrics."
fi

# ------------------------------------------------------------------------------
# Test 5: Alert Cooldown & State Deduplication
# ------------------------------------------------------------------------------
echo "--- 5. Testing Alert Cooldown Suppression ---"
STATE_FILE="/tmp/test_monitor.state"
rm -f "$STATE_FILE"
ALERT_COOLDOWN_MINUTES=30

# First alert should trigger (return code 1: do not suppress)
if ! should_suppress_alert "CPU_SPIKE" "WARN"; then
    pass "Initial alert successfully recorded and allowed through."
else
    fail "Initial alert was prematurely suppressed."
fi

# Immediate second identical alert should be suppressed (return code 0)
if should_suppress_alert "CPU_SPIKE" "WARN"; then
    pass "Duplicate alert within cooldown window was successfully suppressed."
else
    fail "Duplicate alert was not suppressed during cooldown window."
fi

# Escalation from WARN to CRITICAL should break through cooldown
if ! should_suppress_alert "CPU_SPIKE" "CRITICAL"; then
    pass "Escalation from WARN to CRITICAL broke through cooldown window."
else
    fail "Escalation was incorrectly suppressed by cooldown."
fi

rm -f "$STATE_FILE"

# ------------------------------------------------------------------------------
# Summary
# ------------------------------------------------------------------------------
echo ""
echo "================================================================================"
echo -e "Test Results: ${GREEN}${TESTS_PASSED} Passed${RESET}, ${RED}${TESTS_FAILED} Failed${RESET}"
echo "================================================================================"

if [[ $TESTS_FAILED -eq 0 ]]; then
    exit 0
else
    exit 1
fi
