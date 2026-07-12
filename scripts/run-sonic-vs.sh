#!/bin/bash
# run-sonic-vs.sh — Start SONiC-VS container from locally-built image
#
# Uses the docker-sonic-vs image built by sonic-buildimage
# (make target/sonic-vs.img.gz produces target/docker-sonic-vs.gz).
# Loads the image if not already present, then starts the container.
#
# Usage:
#   ./run-sonic-vs.sh                    # start with defaults
#   ./run-sonic-vs.sh -h                 # show help
#
# Environment:
#   SONIC_BUILDIMAGE_ROOT  — path to sonic-buildimage (default: auto-detect)
#   SONIC_VS_IMAGE         — Docker image name (default: docker-sonic-vs:latest)
#   SONIC_VS_CONTAINER     — container name (default: sonic-vs)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SONIC_DEV_LAB="$(dirname "$SCRIPT_DIR")"
SONIC_ROOT="${SONIC_BUILDIMAGE_ROOT:-$(dirname "$SONIC_DEV_LAB")/sonic-buildimage}"

VS_IMAGE="${SONIC_VS_IMAGE:-docker-sonic-vs:latest}"
VS_CT="${SONIC_VS_CONTAINER:-sonic-vs}"

# --- Help ----------------------------------------------------------------
if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    echo "Usage: $0"
    echo ""
    echo "  Starts a sonic-vs container from the locally-built image."
    echo ""
    echo "  The image is built by:"
    echo "    cd $SONIC_ROOT && make target/sonic-vs.img.gz"
    echo "  Output: target/docker-sonic-vs.gz"
    echo ""
    echo "  Environment:"
    echo "    SONIC_BUILDIMAGE_ROOT   path to sonic-buildimage"
    echo "    SONIC_VS_IMAGE          Docker image (default: docker-sonic-vs:latest)"
    echo "    SONIC_VS_CONTAINER      container name (default: sonic-vs)"
    exit 0
fi

echo "=== SONiC-VS ==="

# --- Load image if not present -------------------------------------------
if ! docker images --format '{{.Repository}}:{{.Tag}}' | grep -qx "$VS_IMAGE"; then
    local tarball="$SONIC_ROOT/target/docker-sonic-vs.gz"
    if [ -f "$tarball" ]; then
        echo "  Loading image from $tarball ..."
        docker load -i "$tarball"
    else
        echo "ERROR: Image '$VS_IMAGE' not found and no tarball at:" >&2
        echo "  $tarball" >&2
        echo "" >&2
        echo "  Build the image first:" >&2
        echo "    cd $SONIC_ROOT && make target/sonic-vs.img.gz" >&2
        exit 1
    fi
fi

# --- Stop/remove existing container --------------------------------------
docker stop "$VS_CT" 2>/dev/null || true
docker rm "$VS_CT" 2>/dev/null || true

# --- Start fresh ----------------------------------------------------------
echo "  Starting container: $VS_CT (image: $VS_IMAGE)"
docker run --privileged -d \
    --name "$VS_CT" \
    -v /var/run/docker.sock:/var/run/docker.sock \
    "$VS_IMAGE"

echo "  Waiting for SONiC-VS to start..."
sleep 10

# --- Verify ---------------------------------------------------------------
if docker ps --format '{{.Names}}' | grep -qx "$VS_CT"; then
    echo ""
    echo "=== SONiC-VS is running ==="
    echo "  Connect:  docker exec -it $VS_CT bash"
    echo "  Logs:     docker logs $VS_CT"
else
    echo "ERROR: Container '$VS_CT' failed to start. Check logs:" >&2
    echo "  docker logs $VS_CT" >&2
    exit 1
fi
