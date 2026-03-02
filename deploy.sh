#!/bin/bash

set -e

echo "Starting deployment..."

if [ -z "$PAGERDUTY_ROUTING_KEY" ]; then
    echo "Error: PAGERDUTY_ROUTING_KEY environment variable is not set"
    exit 1
fi

docker-compose down
docker-compose build
docker-compose up -d

sleep 5

curl -f http://localhost:5000/health || exit 1

echo "Deployment complete. Service is running on port 5000"