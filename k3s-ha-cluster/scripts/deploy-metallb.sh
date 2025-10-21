#!/bin/bash
set -e

# Deploy MetalLB LoadBalancer

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
MANIFEST_DIR="$SCRIPT_DIR/../manifests"

log_info "Deploying MetalLB LoadBalancer..."
echo ""

# Install MetalLB
log_info "Installing MetalLB..."
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.0/config/manifests/metallb-native.yaml

log_info "Waiting for MetalLB to be ready..."
kubectl wait --namespace metallb-system \
    --for=condition=ready pod \
    --selector=app=metallb \
    --timeout=90s

echo ""
log_warn "IMPORTANT: You need to configure the IP address pool!"
echo ""
echo "The default configuration uses: 100.100.100.20-100.100.100.30"
echo ""
read -p "$(echo -e ${CYAN}"Do you want to customize the IP range? (yes/no) [no]: "${NC})" CUSTOMIZE
CUSTOMIZE=${CUSTOMIZE:-no}

if [ "$CUSTOMIZE" == "yes" ]; then
    read -p "$(echo -e ${CYAN}"Enter IP range start: "${NC})" IP_START
    read -p "$(echo -e ${CYAN}"Enter IP range end: "${NC})" IP_END

    # Create custom manifest
    cat > /tmp/metallb-ippool.yaml <<EOF
---
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: tailscale-pool
  namespace: metallb-system
spec:
  addresses:
  - $IP_START-$IP_END
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: tailscale-advert
  namespace: metallb-system
spec:
  ipAddressPools:
  - tailscale-pool
  interfaces:
  - tailscale0
EOF

    log_info "Applying custom IP pool..."
    kubectl apply -f /tmp/metallb-ippool.yaml
else
    log_info "Applying default IP pool (100.100.100.20-30)..."
    kubectl apply -f "$MANIFEST_DIR/network/metallb-ippool.yaml"
fi

echo ""
log_info "MetalLB deployment complete!"
echo ""
