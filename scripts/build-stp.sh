#!/bin/bash
# build-stp.sh — Build stpd + stpmgrd and deploy to sonic-vs container
#
# Builds the STP submodule components:
#   - stpd    (src/sonic-stp)          — STP daemon
#   - stpmgrd (src/sonic-swss/cfgmgr)  — STP configuration manager
#
# Usage:
#   ./build-stp.sh              # build + deploy + restart
#   ./build-stp.sh -h           # show help
#
# Environment variables (all optional):
#   SONIC_BUILDIMAGE_ROOT  — path to sonic-buildimage repo on host
#   SONIC_BUILD_CONTAINER  — name of sonic-slave container (default: auto-detect)
#   SONIC_VS_CONTAINER     — name of sonic-vs container (default: sonic-vs)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/container-detect.sh"

# --- Help ----------------------------------------------------------------
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    echo "Usage: $0"
    echo ""
    echo "  Builds stpd and stpmgrd inside the sonic-slave container,"
    echo "  copies the binaries into sonic-vs, and restarts both services."
    echo ""
    echo "  Environment:"
    echo "    SONIC_BUILDIMAGE_ROOT   path to sonic-buildimage (default: auto-detect)"
    echo "    SONIC_BUILD_CONTAINER   build container name (default: auto-detect)"
    echo "    SONIC_VS_CONTAINER      target container name (default: sonic-vs)"
    exit 0
fi

check_cmd docker

# --- Resolve paths -------------------------------------------------------
SONIC_DEV_LAB="$(dirname "$SCRIPT_DIR")"
SONIC_ROOT="${SONIC_BUILDIMAGE_ROOT:-$(dirname "$SONIC_DEV_LAB")/sonic-buildimage}"
VS_CT="${SONIC_VS_CONTAINER:-sonic-vs}"

# --- Ensure containers are running ---------------------------------------
echo "=== stp: pre-flight checks ==="
BUILD_CT="$(ensure_build_container "$SONIC_ROOT")"
check_container_running "$VS_CT"

echo "  Build image root : $SONIC_ROOT"
echo "  Build container  : $BUILD_CT"
echo "  Target container : $VS_CT"

# --- Compile stpd (src/sonic-stp) ----------------------------------------
STP_SRC="/sonic/src/sonic-stp"
STPD_BIN="stpd"
STPD_HOST="$SONIC_ROOT/src/sonic-stp/$STPD_BIN"
STPD_DEST="/usr/bin/$STPD_BIN"

echo ""
echo "=== stp: compiling stpd ==="
docker exec "$BUILD_CT" make -C "$STP_SRC" stpd -j"$(nproc)"

if [ ! -f "$STPD_HOST" ]; then
    echo "ERROR: Build succeeded but stpd binary not found at '$STPD_HOST'." >&2
    exit 1
fi
echo "  stpd binary: $STPD_HOST"

# --- Compile stpmgrd (src/sonic-swss/cfgmgr) -----------------------------
SWSS_SRC="/sonic/src/sonic-swss"
STPMGRD_BIN="stpmgrd"
STPMGRD_HOST="$SONIC_ROOT/src/sonic-swss/cfgmgr/$STPMGRD_BIN"
STPMGRD_DEST="/usr/bin/$STPMGRD_BIN"

echo ""
echo "=== stp: compiling stpmgrd ==="
docker exec "$BUILD_CT" make -C "$SWSS_SRC/cfgmgr" stpmgrd -j"$(nproc)"

if [ ! -f "$STPMGRD_HOST" ]; then
    echo "ERROR: Build succeeded but stpmgrd binary not found at '$STPMGRD_HOST'." >&2
    exit 1
fi
echo "  stpmgrd binary: $STPMGRD_HOST"

# --- Deploy ----------------------------------------------------------------
echo ""
echo "=== stp: deploying ==="

docker cp "$STPD_HOST" "$VS_CT:$STPD_DEST"
echo "  Copied stpd to $VS_CT:$STPD_DEST"

docker cp "$STPMGRD_HOST" "$VS_CT:$STPMGRD_DEST"
echo "  Copied stpmgrd to $VS_CT:$STPMGRD_DEST"

# --- Restart ---------------------------------------------------------------
# stpd is NOT managed by supervisor — kill old process and start new
docker exec "$VS_CT" bash -c 'kill $(pgrep -x stpd) 2>/dev/null || true; sleep 1; nohup /usr/bin/stpd > /dev/null 2>&1 &'
echo "  stpd restarted (standalone)"

# stpmgrd IS managed by supervisor
docker exec "$VS_CT" supervisorctl restart stpmgrd
echo "  stpmgrd restarted (supervisor)"

echo ""
echo "=== stp: done ==="
