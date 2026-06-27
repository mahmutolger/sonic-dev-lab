#!/bin/bash
# SONiC Dev Lab - Setup Script
# Run this on any new machine to get started

echo "=== SONiC Dev Lab Setup ==="

# 1. Install dependencies
echo "[1/4] Installing dependencies..."
sudo apt update
sudo apt install -y docker.io git python3 python3-pip curl

# 2. Setup Docker
echo "[2/4] Setting up Docker..."
sudo usermod -aG docker $USER
sudo systemctl enable docker
sudo systemctl start docker

# 3. Fix Docker permissions immediately (no logout needed)
echo "[3/4] Fixing Docker permissions..."
newgrp docker

# 4. Pull SONiC-VS image
echo "[4/4] Pulling SONiC-VS Docker image..."
docker pull netreplica/docker-sonic-vs

echo ""
echo "=== Setup Complete! ==="
echo "Now run: ./scripts/run-sonic-vs.sh"
