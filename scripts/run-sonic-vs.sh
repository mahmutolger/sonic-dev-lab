#!/bin/bash
# Start SONiC-VS container

echo "=== Starting SONiC-VS ==="

# Stop existing container if running
docker stop sonic-vs 2>/dev/null
docker rm sonic-vs 2>/dev/null

# Start fresh with correct image
docker run --privileged -d \
  --name sonic-vs \
  netreplica/docker-sonic-vs

echo "Waiting for SONiC-VS to start..."
sleep 10

echo "=== SONiC-VS is running! ==="
echo "Connect with: docker exec -it sonic-vs bash"
echo "Check logs:   docker logs sonic-vs"
