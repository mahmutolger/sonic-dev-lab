#!/bin/bash
# test-vlan-pipeline.sh — Run VLAN create/delete cycles and verify all 4 log points
#
# Usage:
#   ./test-vlan-pipeline.sh              # 1 cycle with VLAN 500
#   ./test-vlan-pipeline.sh -n 3         # 3 cycles
#   ./test-vlan-pipeline.sh -v 600       # use VLAN 600
#
# Requires: sonic-vs container running, redis-cli available inside it

set -euo pipefail

VS_CT="${SONIC_VS_CONTAINER:-sonic-vs}"
CYCLES=1
VLAN_ID=500
PORT="Ethernet8"

# --- Parse args ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        -n) CYCLES="$2"; shift 2 ;;
        -v) VLAN_ID="$2"; shift 2 ;;
        -p) PORT="$2"; shift 2 ;;
        -c) VS_CT="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [-n cycles] [-v vlan_id] [-p port] [-c container]"
            echo ""
            echo "  -n  Number of create/delete cycles (default: 1)"
            echo "  -v  VLAN ID to use (default: 500)"
            echo "  -p  Port to add as member (default: Ethernet8)"
            echo "  -c  sonic-vs container name (default: sonic-vs)"
            exit 0
            ;;
        *) echo "Unknown flag: $1"; exit 1 ;;
    esac
done

VLAN_KEY="Vlan${VLAN_ID}"
MEMBER_KEY="Vlan${VLAN_ID}|${PORT}"

# --- Pre-flight ---
if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$VS_CT"; then
    echo "ERROR: Container '$VS_CT' is not running." >&2
    exit 1
fi

echo "=== VLAN Pipeline Test ==="
echo "  Container : $VS_CT"
echo "  VLAN      : $VLAN_KEY"
echo "  Port      : $PORT"
echo "  Cycles    : $CYCLES"
echo ""

for ((i=1; i<=CYCLES; i++)); do
    echo "--- Cycle $i/$CYCLES ---"

    # --- CREATE ---
    echo "  [1/4] Creating VLAN ${VLAN_KEY} in CONFIG_DB..."
    docker exec "$VS_CT" redis-cli -n 4 HSET "VLAN|${VLAN_KEY}" "admin_status" "up" "mtu" "9100" > /dev/null
    sleep 1

    echo "  [2/4] Adding member ${PORT} to ${VLAN_KEY}..."
    docker exec "$VS_CT" redis-cli -n 4 HSET "VLAN_MEMBER|${MEMBER_KEY}" "tagging_mode" "untagged" > /dev/null
    sleep 1

    echo "  [3/4] Checking SET logs..."
    docker exec "$VS_CT" bash -c "grep MAHMUT /var/log/syslog | grep '${VLAN_KEY}' | grep -E 'SET|DEL'" | tail -4 | while read -r line; do
        echo "        $line"
    done

    # --- DELETE ---
    echo "  [4/4] Deleting ${VLAN_KEY}..."
    docker exec "$VS_CT" redis-cli -n 4 DEL "VLAN_MEMBER|${MEMBER_KEY}" > /dev/null
    sleep 1
    docker exec "$VS_CT" redis-cli -n 4 DEL "VLAN|${VLAN_KEY}" > /dev/null
    sleep 1

    echo "        DEL logs:"
    docker exec "$VS_CT" bash -c "grep MAHMUT /var/log/syslog | grep '${VLAN_KEY}' | grep DEL" | tail -4 | while read -r line; do
        echo "        $line"
    done

    echo ""
done

# --- Summary ---
echo "=== Summary: All MAHMUT logs for last cycle ==="
docker exec "$VS_CT" bash -c "grep MAHMUT /var/log/syslog | grep -E '${VLAN_KEY}' | grep -E 'vlanmgrd::doVlan|orchagent::doVlan'" | tail -8

echo ""
echo "=== Pipeline verification ==="
SET_COUNT=$(docker exec "$VS_CT" bash -c "grep MAHMUT /var/log/syslog | grep '${VLAN_KEY}' | grep SET | wc -l")
DEL_COUNT=$(docker exec "$VS_CT" bash -c "grep MAHMUT /var/log/syslog | grep '${VLAN_KEY}' | grep DEL | wc -l")
echo "  SET logs: $SET_COUNT  (expect $((4 * CYCLES)))"
echo "  DEL logs: $DEL_COUNT  (expect $((4 * CYCLES)))"

if [ "$SET_COUNT" -ge $((4 * CYCLES)) ] && [ "$DEL_COUNT" -ge $((4 * CYCLES)) ]; then
    echo "  Status: PASS ✓"
else
    echo "  Status: FAIL ✗ — some log points missed"
fi
