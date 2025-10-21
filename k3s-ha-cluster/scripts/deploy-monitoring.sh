#!/bin/bash
set -e

# Deploy Prometheus Stack for monitoring

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

log_info "Deploying Prometheus monitoring stack..."
echo ""

# Check if Longhorn is installed
if ! kubectl get storageclass longhorn-replicated &> /dev/null; then
    log_error "Longhorn StorageClass not found!"
    log_error "Please run: ./deploy-longhorn.sh first"
    exit 1
fi

# Check if helm is installed
if ! command -v helm &> /dev/null; then
    log_error "Helm is not installed!"
    log_error "Please install Helm: https://helm.sh/docs/intro/install/"
    exit 1
fi

# Add Prometheus repository
log_info "Adding Prometheus Helm repository..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# Create namespace
log_info "Creating monitoring namespace..."
kubectl create namespace monitoring || true

# Install Prometheus stack
log_info "Installing kube-prometheus-stack (this may take 5-10 minutes)..."
helm install prometheus prometheus-community/kube-prometheus-stack \
    --namespace monitoring \
    -f "$MANIFEST_DIR/monitoring/prometheus-values.yaml"

log_info "Waiting for Prometheus pods to be ready..."
kubectl wait --namespace monitoring \
    --for=condition=ready pod \
    --selector=app.kubernetes.io/name=prometheus \
    --timeout=300s

kubectl wait --namespace monitoring \
    --for=condition=ready pod \
    --selector=app.kubernetes.io/name=grafana \
    --timeout=300s

echo ""
log_info "Prometheus monitoring stack deployment complete!"
echo ""
log_info "Access Grafana:"
echo "  kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80"
echo "  Then open: http://localhost:3000"
echo "  Login: admin / admin"
echo ""
log_info "Recommended dashboards to import:"
echo "  • 9628: PostgreSQL Database"
echo "  • 15760: Kubernetes Cluster Monitoring"
echo "  • 15757: Kubernetes / Views / Pods"
echo "  • 12113: Longhorn"
echo ""
