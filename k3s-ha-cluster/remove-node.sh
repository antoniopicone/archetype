#!/bin/bash
# Script to remove a node from K3s cluster
# Run this on a master node

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if running on a K3s node
if ! command -v kubectl &> /dev/null; then
    log_error "kubectl not found. Please run this on a K3s master node."
    exit 1
fi

# Show current nodes
log_info "Current cluster nodes:"
kubectl get nodes -o wide

echo ""
read -p "Enter the node name to remove: " NODE_NAME

if [ -z "$NODE_NAME" ]; then
    log_error "Node name cannot be empty!"
    exit 1
fi

# Check if node exists
if ! kubectl get node "$NODE_NAME" &> /dev/null; then
    log_error "Node '$NODE_NAME' not found in the cluster!"
    exit 1
fi

log_warn "This will remove node '$NODE_NAME' from the cluster."
read -p "Are you sure? (yes/no): " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
    log_info "Aborted."
    exit 0
fi

# Drain the node first (if it has workloads)
log_info "Draining node '$NODE_NAME'..."
kubectl drain "$NODE_NAME" --ignore-daemonsets --delete-emptydir-data --force --timeout=60s || log_warn "Drain failed or timed out, continuing anyway..."

# Delete the node
log_info "Deleting node '$NODE_NAME' from cluster..."
if kubectl delete node "$NODE_NAME"; then
    log_info "Node '$NODE_NAME' successfully removed from cluster!"
    echo ""
    log_info "Remaining nodes:"
    kubectl get nodes -o wide
else
    log_error "Failed to delete node '$NODE_NAME'"
    exit 1
fi

echo ""
log_info "Done! If the node was a witness or master, you may also need to:"
log_info "1. Clean up etcd member if it's stuck (check with: kubectl get etcdsnapshotfile -A)"
log_info "2. On the removed node, run the cleanup script to remove K3s completely"
