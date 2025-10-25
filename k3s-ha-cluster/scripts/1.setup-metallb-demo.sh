#!/bin/bash
set -e

# MetalLB + Nginx Demo Setup Script
# This script can be run from any K3s master node
# It will:
# 1. Configure Tailscale subnet routes
# 2. Install MetalLB without webhooks
# 3. Deploy nginx with LoadBalancer

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
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

log_step() {
    echo ""
    echo -e "${CYAN}========================================${NC}"
    echo -e "${CYAN}$1${NC}"
    echo -e "${CYAN}========================================${NC}"
}

# Check if running as root or with sudo
if [ "$EUID" -eq 0 ]; then
    SUDO=""
else
    SUDO="sudo"
fi

# Configuration - read from environment or use defaults
METALLB_SUBNET="${METALLB_SUBNET:-100.106.200.0/24}"
METALLB_IP_RANGE="${METALLB_IP_RANGE:-100.106.200.10-100.106.200.50}"
METALLB_VERSION="v0.15.2"
NAMESPACE="metallb-system"

log_step "Step 1: Configure Tailscale Subnet Routes"

# Get Tailscale IP
TAILSCALE_IP=$($SUDO tailscale ip -4 2>/dev/null || echo "")
if [ -z "$TAILSCALE_IP" ]; then
    log_error "Tailscale not running or not connected!"
    exit 1
fi

log_info "This node's Tailscale IP: $TAILSCALE_IP"

# Enable IP forwarding
log_info "Enabling IP forwarding..."
$SUDO sysctl -w net.ipv4.ip_forward=1 >/dev/null
if ! grep -q "net.ipv4.ip_forward=1" /etc/sysctl.conf 2>/dev/null; then
    echo "net.ipv4.ip_forward=1" | $SUDO tee -a /etc/sysctl.conf >/dev/null
fi

# Get current advertised routes
CURRENT_ROUTES=$($SUDO tailscale status --json | jq -r '.Self.AllowedIPs[]' 2>/dev/null | grep -v ":" | tr '\n' ',' | sed 's/,$//')

if [ -z "$CURRENT_ROUTES" ]; then
    ADVERTISE_ROUTES="$METALLB_SUBNET"
else
    # Add MetalLB subnet to existing routes
    if echo "$CURRENT_ROUTES" | grep -q "$METALLB_SUBNET"; then
        log_info "Subnet $METALLB_SUBNET already advertised"
        ADVERTISE_ROUTES="$CURRENT_ROUTES"
    else
        ADVERTISE_ROUTES="$CURRENT_ROUTES,$METALLB_SUBNET"
    fi
fi

log_info "Advertising routes: $ADVERTISE_ROUTES"
$SUDO tailscale up --advertise-routes="$ADVERTISE_ROUTES" --accept-routes 2>&1 | grep -v "Warning: UDP GRO" || true

log_warn ""
log_warn "IMPORTANT: You must approve the subnet route in Tailscale Admin Console!"
log_warn "1. Go to: https://login.tailscale.com/admin/machines"
log_warn "2. Find this machine in the list"
log_warn "3. Click 'Edit route settings' and approve: $METALLB_SUBNET"
log_warn ""
read -p "$(echo -e ${CYAN}"Press ENTER when you have approved the route..."${NC})"

log_step "Step 2: Install MetalLB"

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    log_error "kubectl not found! Make sure you're on a K3s node."
    exit 1
fi

# Check if we can connect to the cluster
if ! kubectl get nodes &>/dev/null; then
    log_error "Cannot connect to Kubernetes cluster!"
    exit 1
fi

# Clean up any existing MetalLB installation
log_info "Cleaning up any existing MetalLB installation..."
kubectl delete namespace $NAMESPACE --wait=true 2>/dev/null || true
kubectl delete deployment nginx --wait=true 2>/dev/null || true
kubectl delete service nginx --wait=true 2>/dev/null || true
kubectl delete validatingwebhookconfiguration metallb-webhook-configuration 2>/dev/null || true
kubectl delete mutatingwebhookconfiguration metallb-webhook-configuration 2>/dev/null || true

# Wait a bit for cleanup
sleep 5

# Install MetalLB
log_info "Installing MetalLB $METALLB_VERSION..."
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/$METALLB_VERSION/config/manifests/metallb-native.yaml

log_info "Waiting for MetalLB namespace to be created..."
kubectl wait --for=jsonpath='{.status.phase}'=Active namespace/$NAMESPACE --timeout=30s

# Delete webhooks immediately to avoid issues
log_info "Removing webhooks to avoid timeout issues..."
sleep 5
kubectl delete validatingwebhookconfiguration metallb-webhook-configuration 2>/dev/null || true
kubectl delete mutatingwebhookconfiguration metallb-webhook-configuration 2>/dev/null || true

# Patch deployments to tolerate all taints
log_info "Patching MetalLB controller to tolerate all taints..."
kubectl patch deployment -n $NAMESPACE controller --type=json -p='[
  {
    "op": "add",
    "path": "/spec/template/spec/tolerations",
    "value": [{"operator": "Exists"}]
  }
]' 2>/dev/null || true

log_info "Patching MetalLB speaker to tolerate all taints..."
kubectl patch daemonset -n $NAMESPACE speaker --type=json -p='[
  {
    "op": "add",
    "path": "/spec/template/spec/tolerations",
    "value": [{"operator": "Exists"}]
  }
]' 2>/dev/null || true

log_info "Waiting for MetalLB pods to be ready..."
kubectl wait --namespace $NAMESPACE \
    --for=condition=ready pod \
    --selector=app=metallb \
    --timeout=120s || log_warn "Some pods may still be starting..."

# Verify pods are running
log_info "MetalLB pods status:"
kubectl get pods -n $NAMESPACE -o wide

log_step "Step 3: Configure MetalLB IP Pool"

log_info "Creating IPAddressPool and L2Advertisement..."
cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: tailscale-pool
  namespace: $NAMESPACE
spec:
  addresses:
  - $METALLB_IP_RANGE
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: tailscale-advert
  namespace: $NAMESPACE
spec:
  ipAddressPools:
  - tailscale-pool
  interfaces:
  - tailscale0
EOF

log_info "Verifying IP pool configuration..."
kubectl get ipaddresspool,l2advertisement -n $NAMESPACE

log_step "Step 4: Deploy Nginx with LoadBalancer"

log_info "Creating nginx deployment..."
kubectl create deployment nginx --image=nginx --replicas=2

log_info "Waiting for nginx deployment to be ready..."
kubectl wait --for=condition=available deployment/nginx --timeout=60s

log_info "Exposing nginx with LoadBalancer service..."
kubectl expose deployment nginx --port=80 --type=LoadBalancer

log_info "Waiting for LoadBalancer IP to be assigned..."
TIMEOUT=60
ELAPSED=0
while [ $ELAPSED -lt $TIMEOUT ]; do
    EXTERNAL_IP=$(kubectl get svc nginx -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "")

    if [ -n "$EXTERNAL_IP" ]; then
        log_info "LoadBalancer IP assigned: $EXTERNAL_IP"
        break
    fi

    echo -n "."
    sleep 2
    ELAPSED=$((ELAPSED + 2))
done
echo ""

if [ -z "$EXTERNAL_IP" ]; then
    log_warn "LoadBalancer IP not assigned within timeout"
    log_warn "Check MetalLB logs: kubectl logs -n $NAMESPACE -l app=metallb"
else
    log_step "Deployment Complete!"

    echo ""
    log_info "Service details:"
    kubectl get svc nginx

    echo ""
    log_info "Testing connectivity from this node..."
    if curl -s -m 5 http://$EXTERNAL_IP >/dev/null 2>&1; then
        log_info "✓ Service is accessible from this node!"
        log_info "  curl http://$EXTERNAL_IP"
    else
        log_warn "✗ Service not accessible yet (may need a few more seconds)"
    fi

    echo ""
    log_info "To test from other Tailscale devices:"
    log_info "  curl http://$EXTERNAL_IP"

    echo ""
    log_info "All cluster nodes:"
    kubectl get nodes -o wide

    echo ""
    log_info "All pods:"
    kubectl get pods -A -o wide | grep -E "NAMESPACE|nginx|metallb"
fi

log_step "Setup Complete!"

echo ""
log_info "Useful commands:"
echo "  - View service: kubectl get svc nginx"
echo "  - View pods: kubectl get pods -A -o wide"
echo "  - Delete demo: kubectl delete deploy nginx; kubectl delete svc nginx"
echo "  - View MetalLB logs: kubectl logs -n $NAMESPACE -l component=controller"
echo ""
