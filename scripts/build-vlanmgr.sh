#!/bin/bash
# build-vlanmgr.sh — Build vlanmgrd and deploy to sonic-vs container
#
# Builds the VLAN manager daemon (vlanmgrd) which implements the
# CONFIG_DB -> vlanmgrd -> APPL_DB pipeline documented in doc/vlan.md.
#
# Usage:
#   ./build-vlanmgr.sh           # build + deploy + restart
#   ./build-vlanmgr.sh -h        # show help
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
    echo "  Builds vlanmgrd inside the sonic-slave container, copies the"
    echo "  binary into sonic-vs, and restarts the service via supervisorctl."
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
echo "=== vlanmgr: pre-flight checks ==="
BUILD_CT="$(ensure_build_container "$SONIC_ROOT")"
check_container_running "$VS_CT"

echo "  Build image root : $SONIC_ROOT"
echo "  Build container  : $BUILD_CT"
echo "  Target container : $VS_CT"

# --- Compile ----------------------------------------------------------------
SWSS_SRC="/sonic/src/sonic-swss"
BINARY_NAME="vlanmgrd"
BINARY_HOST_PATH="$SONIC_ROOT/src/sonic-swss/cfgmgr/$BINARY_NAME"
BINARY_DEST="/usr/bin/$BINARY_NAME"

echo "  Source           : $SWSS_SRC/cfgmgr"
echo ""
echo "=== vlanmgr: compiling ==="
docker exec "$BUILD_CT" make -C "$SWSS_SRC/cfgmgr" vlanmgrd -j"$(nproc)"

if [ ! -f "$BINARY_HOST_PATH" ]; then
    echo "ERROR: Build succeeded but binary not found at '$BINARY_HOST_PATH'." >&2
    exit 1
fi
echo "  Binary: $BINARY_HOST_PATH"

# --- Deploy ----------------------------------------------------------------
echo ""
echo "=== vlanmgr: deploying ==="
docker cp "$BINARY_HOST_PATH" "$VS_CT:$BINARY_DEST"
echo "  Copied to $VS_CT:$BINARY_DEST"

docker exec "$VS_CT" supervisorctl restart vlanmgrd
echo "  vlanmgrd restarted (supervisor)"

echo ""
echo "=== vlanmgr: done ==="
