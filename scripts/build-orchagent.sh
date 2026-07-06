#!/bin/bash
# build-orchagent.sh — Build orchagent and deploy to sonic-vs container
#
# Linux-only (requires Docker and a SONiC build environment).
#
# Required environment:
#   The following are auto-detected but can be overridden via env vars:
#     SONIC_BUILDIMAGE_ROOT  — path to the sonic-buildimage repo on the host
#     SONIC_BUILD_CONTAINER  — name of the sonic-slave/build container (default: sonic-build)
#     SONIC_VS_CONTAINER     — name of the sonic-vs target container (default: sonic-vs)
#
# Prerequisites:
#   - Docker installed and accessible (user in 'docker' group, daemon running)
#   - sonic-build container running with host source mounted at /sonic
#   - sonic-vs container running

set -euo pipefail

# ---------------------------------------------------------------------------
# Dependency checks
# ---------------------------------------------------------------------------
check_cmd() {
    if ! command -v "$1" &>/dev/null; then
        echo "ERROR: '$1' not found. Please install it first." >&2
        exit 1
    fi
}

check_container_running() {
    local name="$1"
    if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$name"; then
        echo "ERROR: Container '$name' is not running." >&2
        echo "  Start it or set the correct name via environment variable." >&2
        exit 1
    fi
}

check_cmd docker

# --- Resolve paths and container names ------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SONIC_DEV_LAB="$(dirname "$SCRIPT_DIR")"
SONIC_ROOT="${SONIC_BUILDIMAGE_ROOT:-$(dirname "$SONIC_DEV_LAB")/sonic-buildimage}"

BUILD_CT="${SONIC_BUILD_CONTAINER:-sonic-build}"
VS_CT="${SONIC_VS_CONTAINER:-sonic-vs}"

# Container-internal source/build paths (convention inside sonic-slave)
SWSS_SRC="/sonic/src/sonic-swss"
ORCHAGENT_SRC="$SWSS_SRC/orchagent"
BINARY_NAME="orchagent"
BINARY_HOST_PATH="$SONIC_ROOT/src/sonic-swss/orchagent/$BINARY_NAME"
BINARY_DEST="/usr/bin/$BINARY_NAME"

# --- Verify everything exists ---------------------------------------------
echo "=== orchagent: pre-flight checks ==="

check_container_running "$BUILD_CT"
check_container_running "$VS_CT"

echo "  Build image root : $SONIC_ROOT"
echo "  Build container  : $BUILD_CT"
echo "  Target container : $VS_CT"
echo "  Source           : $ORCHAGENT_SRC"

# --- Compile ----------------------------------------------------------------
echo "=== orchagent: compiling ==="
docker exec "$BUILD_CT" make -C "$ORCHAGENT_SRC" -j"$(nproc)"

if [ ! -f "$BINARY_HOST_PATH" ]; then
    echo "ERROR: Build succeeded but binary not found at '$BINARY_HOST_PATH'." >&2
    exit 1
fi

echo "  Binary built: $BINARY_HOST_PATH"

# --- Deploy ----------------------------------------------------------------
echo "=== orchagent: deploying ==="

docker cp "$BINARY_HOST_PATH" "$VS_CT:$BINARY_DEST"
echo "  Copied to $VS_CT:$BINARY_DEST"

docker exec "$VS_CT" supervisorctl restart orchagent
echo "  orchagent restarted"

echo "=== orchagent: done ==="
