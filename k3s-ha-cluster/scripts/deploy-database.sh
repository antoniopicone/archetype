#!/bin/bash
set -e

# Deploy PostgreSQL with Patroni HA

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
MANIFEST_DIR="$SCRIPT_DIR/../manifests"

log_info "Deploying PostgreSQL HA with Patroni..."
echo ""

# Check if Longhorn is installed
if ! kubectl get storageclass longhorn-replicated &> /dev/null; then
    log_error "Longhorn StorageClass not found!"
    log_error "Please run: ./deploy-longhorn.sh first"
    exit 1
fi

# Create namespace
log_info "Creating database namespace..."
kubectl apply -f "$MANIFEST_DIR/database/01-namespace.yaml"

# Deploy etcd
log_info "Deploying etcd cluster (3 replicas)..."
kubectl apply -f "$MANIFEST_DIR/database/02-etcd.yaml"

log_info "Waiting for etcd to be ready (this may take 2-3 minutes)..."
sleep 30
kubectl wait --namespace database \
    --for=condition=ready pod \
    --selector=app=etcd \
    --timeout=180s

# Verify etcd
log_info "Verifying etcd cluster..."
kubectl exec -n database etcd-0 -- etcdctl member list || {
    log_error "etcd cluster is not healthy!"
    exit 1
}

# Deploy Patroni
log_info "Deploying Patroni secrets..."
kubectl apply -f "$MANIFEST_DIR/database/03-patroni-secrets.yaml"

log_warn "IMPORTANT: Change the default passwords in manifests/database/03-patroni-secrets.yaml"
echo ""

log_info "Deploying Patroni RBAC..."
kubectl apply -f "$MANIFEST_DIR/database/04-patroni-rbac.yaml"

log_info "Deploying Patroni services..."
kubectl apply -f "$MANIFEST_DIR/database/05-patroni-services.yaml"

log_info "Deploying Patroni StatefulSet (2 replicas)..."
kubectl apply -f "$MANIFEST_DIR/database/06-patroni-statefulset.yaml"

log_info "Waiting for Patroni to be ready (this may take 3-5 minutes)..."
kubectl wait --namespace database \
    --for=condition=ready pod \
    --selector=application=patroni \
    --timeout=300s

# Verify Patroni cluster
log_info "Verifying Patroni cluster..."
sleep 10
kubectl exec -n database patroni-0 -- patronictl list

echo ""
log_info "PostgreSQL HA deployment complete!"
echo ""
log_info "Cluster status:"
kubectl exec -n database patroni-0 -- patronictl list
echo ""
log_info "To connect to PostgreSQL:"
echo "  kubectl exec -it -n database patroni-0 -- psql -U postgres"
echo ""
