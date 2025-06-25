#!/usr/bin/env bash
# User-configurable variables
LATEST_IMAGE="n8nio/n8n:latest"

set -euo pipefail

# Disable AWS CLI pager for non-interactive execution
export AWS_PAGER=""

if ! command -v kubectl >/dev/null 2>&1; then
  echo "kubectl not found" >&2
  exit 1
fi

# Update deployments with the latest image
kubectl set image deployment/n8n n8n="$LATEST_IMAGE" -n n8n
kubectl set image deployment/n8n-worker n8n-worker="$LATEST_IMAGE" -n n8n

# Wait for deployments to roll out
kubectl rollout status deployment/n8n -n n8n
kubectl rollout status deployment/n8n-worker -n n8n

echo "n8n upgrade complete"
