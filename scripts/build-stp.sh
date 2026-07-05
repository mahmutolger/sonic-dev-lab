#!/bin/bash
# Build stpd and deploy to sonic-vs container
# Prerequisite: sonic-build persistent container must be running

set -e

BUILD_CONTAINER="sonic-build"
STP_SRC="/sonic/src/sonic-stp"
BUILDIMAGE_ROOT="/home/mahmut/sonic_workspace/sonic-buildimage"

echo "=== Building stpd ==="

# Compile
docker exec "$BUILD_CONTAINER" make -C "$STP_SRC" -j4

# Deploy
docker cp "$BUILDIMAGE_ROOT/src/sonic-stp/stpd" sonic-vs:/usr/bin/stpd

# Restart (stpd runs standalone, not via supervisor)
docker exec sonic-vs bash -c 'kill $(pgrep -x stpd) 2>/dev/null; sleep 1; nohup /usr/bin/stpd > /dev/null 2>&1 &'

echo "=== stpd deployed and restarted ==="

# Show log
sleep 1
docker exec sonic-vs grep "Mahmut claude agent" /var/log/syslog | tail -1
