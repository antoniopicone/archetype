#!/bin/bash
set -e

# Deploy Vaultwarden password manager

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

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
MANIFEST_DIR="$SCRIPT_DIR/../manifests"

log_info "Deploying Vaultwarden password manager..."
echo ""

# Check if PostgreSQL is running
if ! kubectl get pods -n database -l application=patroni | grep -q Running; then
    log_error "PostgreSQL is not running!"
    log_error "Please run: ./deploy-database.sh first"
    exit 1
fi

# Create database and user
log_info "Creating Vaultwarden database..."
echo ""
read -p "$(echo -e ${CYAN}"Enter Vaultwarden database password: "${NC})" DB_PASSWORD

kubectl exec -it -n database patroni-0 -- psql -U postgres << EOF
CREATE DATABASE vaultwarden;
CREATE USER vaultwarden WITH PASSWORD '$DB_PASSWORD';
GRANT ALL PRIVILEGES ON DATABASE vaultwarden TO vaultwarden;
\q
EOF

log_info "Database created successfully!"
echo ""

# Update secret with correct password
log_info "Updating Vaultwarden secret..."
DB_URL="postgresql://vaultwarden:$DB_PASSWORD@patroni.database.svc.cluster.local:5432/vaultwarden"

cat > /tmp/vaultwarden-secret.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: vaultwarden-secret
  namespace: apps
type: Opaque
stringData:
  DATABASE_URL: "$DB_URL"
EOF

# Create namespace
kubectl apply -f "$MANIFEST_DIR/apps/01-namespace.yaml"

# Apply secret
kubectl apply -f /tmp/vaultwarden-secret.yaml

# Deploy Vaultwarden
log_info "Deploying Vaultwarden..."
kubectl apply -f "$MANIFEST_DIR/apps/03-vaultwarden-deployment.yaml"

log_info "Waiting for Vaultwarden to be ready..."
kubectl wait --namespace apps \
    --for=condition=ready pod \
    --selector=app=vaultwarden \
    --timeout=180s

# Get LoadBalancer IP
log_info "Getting LoadBalancer IP..."
sleep 10
LB_IP=$(kubectl get svc -n apps vaultwarden-lb -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

if [ -z "$LB_IP" ]; then
    log_warn "LoadBalancer IP not assigned yet!"
    log_warn "Check with: kubectl get svc -n apps vaultwarden-lb"
else
    echo ""
    log_info "Vaultwarden deployment complete!"
    echo ""
    log_info "Access Vaultwarden at: http://$LB_IP:8080"
    echo ""
    log_info "To configure DNS:"
    echo "  Add this IP to your Tailscale DNS or /etc/hosts:"
    echo "  $LB_IP  vaultwarden.internal"
    echo ""
fi
