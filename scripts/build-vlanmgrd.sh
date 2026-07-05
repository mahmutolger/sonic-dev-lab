#!/bin/bash
# Build vlanmgrd and deploy to sonic-vs container
# Prerequisite: sonic-build persistent container must be running
#               (see build-stp.sh for setup steps)

set -e

BUILD_CONTAINER="sonic-build"
SWSS_SRC="/sonic/src/sonic-swss"
BUILDIMAGE_ROOT="/home/mahmut/sonic_workspace/sonic-buildimage"

echo "=== Building vlanmgrd ==="

# Compile
docker exec "$BUILD_CONTAINER" make -C "$SWSS_SRC/cfgmgr" vlanmgrd -j4

# Deploy
docker cp "$BUILDIMAGE_ROOT/src/sonic-swss/cfgmgr/vlanmgrd" sonic-vs:/usr/bin/vlanmgrd

# Restart
docker exec sonic-vs supervisorctl restart vlanmgrd

echo "=== vlanmgrd deployed and restarted ==="

# Show log
sleep 1
docker exec sonic-vs grep "Mahmut claude agent" /var/log/syslog | tail -1
