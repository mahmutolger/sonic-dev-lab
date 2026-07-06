#!/bin/bash
# SONiC Dev Lab - Setup Script
# Run this on any new machine to get started
set -e

echo "=== SONiC Dev Lab Setup ==="

# 1. Check dependencies (skip apt if already installed)
echo "[1/3] Checking dependencies..."
MISSING=""
for pkg in docker.io git python3 python3-pip curl; do
    if ! dpkg -s "$pkg" &>/dev/null; then
        MISSING="$MISSING $pkg"
    fi
done
if [ -n "$MISSING" ]; then
    echo "Installing missing packages:$MISSING"
    sudo apt update
    sudo apt install -y $MISSING
else
    echo "All packages already installed."
fi

# 2. Check Docker
echo "[2/3] Checking Docker..."
if docker info &>/dev/null; then
    echo "Docker is running and accessible."
else
    echo "Docker not accessible. Ensure your user is in the 'docker' group and docker is running."
    echo "Run: sudo usermod -aG docker \$USER && newgrp docker"
    exit 1
fi

# 3. Pull SONiC-VS image
echo "[3/3] Pulling SONiC-VS Docker image..."
docker pull netreplica/docker-sonic-vs

echo ""
echo "=== Setup Complete! ==="
echo "Now run: ./scripts/run-sonic-vs.sh"
