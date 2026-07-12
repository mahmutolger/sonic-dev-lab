#!/bin/bash
# container-detect.sh — Shared container-detection functions for build scripts
#
# Source this from other scripts:
#   SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
#   source "$SCRIPT_DIR/lib/container-detect.sh"
#
# Provides:
#   detect_build_container()   — find a running sonic-slave container
#   ensure_build_container()   — find or start a persistent build container
#   check_container_running()  — generic container-running check
#   check_cmd()                — verify a command is available

# ---------------------------------------------------------------------------
# check_cmd — verify a command exists, exit with error if not
# ---------------------------------------------------------------------------
check_cmd() {
    if ! command -v "$1" &>/dev/null; then
        echo "ERROR: '$1' not found. Please install it first." >&2
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# check_container_running — verify a named container is running
# ---------------------------------------------------------------------------
check_container_running() {
    local name="$1"
    if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$name"; then
        echo "ERROR: Container '$name' is not running." >&2
        echo "  Start it or set the correct name via environment variable." >&2
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# detect_build_container — find a running sonic-slave container by image name
#
# Scans all running containers for one whose image contains 'sonic-slave'.
# Falls back to SONIC_BUILD_CONTAINER env var, then 'sonic-build'.
# ---------------------------------------------------------------------------
detect_build_container() {
    local detected
    detected=$(docker ps --format '{{.Names}}' 2>/dev/null | while read -r cname; do
        if docker inspect "$cname" --format '{{.Config.Image}}' 2>/dev/null | grep -q 'sonic-slave'; then
            echo "$cname"
            return
        fi
    done)
    if [ -n "$detected" ]; then
        echo "$detected"
    else
        echo "${SONIC_BUILD_CONTAINER:-sonic-build}"
    fi
}

# ---------------------------------------------------------------------------
# ensure_build_container — guarantee a running sonic-slave build container
#
# 1. Check SONIC_BUILD_CONTAINER env var (explicit override)
# 2. Scan running containers for sonic-slave image
# 3. If stopped container named 'sonic-build' exists, restart it
# 4. Otherwise, start a new persistent background container
#
# Requires: $1 = path to sonic-buildimage on host (or set SONIC_ROOT)
# Returns:  prints container name to stdout; status messages to stderr
# ---------------------------------------------------------------------------
ensure_build_container() {
    local cname
    local sonic_root="${1:-${SONIC_ROOT}}"

    if [ -z "$sonic_root" ] || [ ! -d "$sonic_root" ]; then
        echo "ERROR: SONIC_ROOT is not set or not a directory: ${sonic_root:-<unset>}" >&2
        echo "  Set SONIC_BUILDIMAGE_ROOT or ensure sonic-buildimage is at the expected path." >&2
        exit 1
    fi

    # 1. Explicit override via SONIC_BUILD_CONTAINER env var
    if [ -n "${SONIC_BUILD_CONTAINER:-}" ]; then
        if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$SONIC_BUILD_CONTAINER"; then
            echo "  [build container] Using (env override): $SONIC_BUILD_CONTAINER" >&2
            echo "$SONIC_BUILD_CONTAINER"
            return 0
        fi
        if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "$SONIC_BUILD_CONTAINER"; then
            echo "  [build container] '$SONIC_BUILD_CONTAINER' is stopped. Restarting..." >&2
            docker start "$SONIC_BUILD_CONTAINER" >&2
            echo "$SONIC_BUILD_CONTAINER"
            return 0
        fi
        echo "ERROR: SONIC_BUILD_CONTAINER='$SONIC_BUILD_CONTAINER' specified but no such container exists." >&2
        exit 1
    fi

    # 2. Scan running containers for sonic-slave image
    local detected
    detected=$(docker ps --format '{{.Names}}' 2>/dev/null | while read -r cname; do
        if docker inspect "$cname" --format '{{.Config.Image}}' 2>/dev/null | grep -q 'sonic-slave'; then
            echo "$cname"
            return
        fi
    done)

    if [ -n "$detected" ]; then
        echo "  [build container] Detected (running): $detected" >&2
        echo "$detected"
        return 0
    fi

    # 3. Check for stopped 'sonic-build' container
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx 'sonic-build'; then
        echo "  [build container] 'sonic-build' is stopped. Restarting..." >&2
        docker start sonic-build >&2
        echo "sonic-build"
        return 0
    fi

    # 4. Start a new persistent background container
    local slave_image
    slave_image=$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep 'sonic-slave-' | grep -v '<none>' | head -1)

    if [ -z "$slave_image" ]; then
        echo "" >&2
        echo "ERROR: No sonic-slave Docker image found." >&2
        echo "" >&2
        echo "  The sonic-slave image must be built before running build scripts." >&2
        echo "  Run this command first:" >&2
        echo "" >&2
        echo "    cd $sonic_root && make sonic-slave-bash" >&2
        echo "" >&2
        echo "  This will build the image and drop you into a shell." >&2
        echo "  After that, re-run this script." >&2
        exit 1
    fi

    echo "  [build container] Starting new persistent container (image: $slave_image)..." >&2
    cname="sonic-build"

    docker rm -f "$cname" 2>/dev/null || true

    docker run -d --name "$cname" \
        --privileged --init \
        -v "$sonic_root:/sonic" \
        -w /sonic \
        "$slave_image" \
        sleep infinity >&2

    echo "  [build container] Started: $cname" >&2
    echo "$cname"
    return 0
}
