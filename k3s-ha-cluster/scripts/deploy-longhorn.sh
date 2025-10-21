#!/bin/bash
set -e

# Deploy Longhorn Distributed Storage

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
MANIFEST_DIR="$SCRIPT_DIR/../manifests"

log_info "Deploying Longhorn distributed storage..."
echo ""

# Install Longhorn
log_info "Installing Longhorn..."
kubectl apply -f https://raw.githubusercontent.com/longhorn/longhorn/v1.6.0/deploy/longhorn.yaml

log_info "Waiting for Longhorn pods to be ready (this may take 3-5 minutes)..."
kubectl wait --namespace longhorn-system \
    --for=condition=ready pod \
    --selector=app=longhorn-manager \
    --timeout=300s

log_info "Creating Longhorn StorageClass..."
kubectl apply -f "$MANIFEST_DIR/storage/longhorn-storageclass.yaml"

echo ""
log_info "Longhorn deployment complete!"
echo ""
log_info "To access Longhorn UI:"
echo "  kubectl port-forward -n longhorn-system svc/longhorn-frontend 8080:80"
echo "  Then open: http://localhost:8080"
echo ""
