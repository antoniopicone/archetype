#!/bin/bash
# NOTE: NON usare 'set -e' perché vogliamo gestire gli errori manualmente
# e mostrare diagnostica dettagliata quando K3s fallisce

# K3s Witness Node Installation Script
# This script installs K3s on a cloud witness node (etcd-only, no workloads)

# Color codes for output
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

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    log_error "Please run as root"
    exit 1
fi


# Funzione di pulizia K3s
clean_k3s() {
    log_warn "Eseguo pulizia completa di K3s (stop, uninstall, rimozione file, variabili d'ambiente e directory residue)"
    systemctl stop k3s 2>/dev/null || true
    /usr/local/bin/k3s-uninstall.sh 2>/dev/null || /usr/bin/k3s-uninstall.sh 2>/dev/null || true
    rm -rf /var/lib/rancher/k3s
    rm -rf /etc/rancher/k3s
    rm -rf /etc/systemd/system/k3s*
    rm -rf /usr/local/bin/k3s*
    rm -rf /usr/bin/k3s*
    rm -rf /run/k3s
    rm -rf /mnt/k3s-storage/k3s
    rm -rf ~/k3s*
    rm -rf ~/.kube
    rm -rf /root/.kube
    rm -rf /etc/cni
    rm -rf /var/lib/cni
    rm -rf /var/lib/kubelet
    rm -rf /var/log/pods
    rm -rf /var/log/containers
    sed -i '/KUBECONFIG/d' ~/.bashrc 2>/dev/null || true
    sed -i '/KUBECONFIG/d' ~/.zshrc 2>/dev/null || true

    # Rimuovi anche i certificati TLS che potrebbero causare problemi
    rm -rf /var/lib/rancher/k3s/server/tls
    rm -rf /var/lib/rancher/k3s/agent

    log_info "Pulizia K3s completata. Tutte le directory e file residui sono stati rimossi."
}

# Esegui la pulizia prima di tutto
clean_k3s

# Check hostname uniqueness
log_info "Checking hostname..."
HOSTNAME=$(hostname)
if [[ "$HOSTNAME" == "localhost" || "$HOSTNAME" == "localhost.localdomain" ]]; then
    log_error "Hostname non valido: $HOSTNAME. Imposta un hostname univoco per ogni nodo!"
    exit 1
fi
log_info "Hostname: $HOSTNAME"

# Check time sync
log_info "Checking time synchronization..."
if ! timedatectl show | grep -q 'NTPSynchronized=yes'; then
    log_warn "NTP non attivo o orario non sincronizzato! Sincronizza l'orario su tutti i nodi."
else
    log_info "NTP attivo e orario sincronizzato."
fi

# Pre-flight checks for Tailscale
log_info "Running pre-flight checks for Tailscale..."

# Check Tailscale status
if ! systemctl is-active --quiet tailscaled; then
    log_error "Tailscale daemon is not running!"
    log_error "Please start Tailscale: sudo systemctl start tailscaled"
    exit 1
fi

# Verify Tailscale is connected
if ! tailscale status &>/dev/null; then
    log_error "Tailscale is not connected!"
    log_error "Please connect: sudo tailscale up"
    exit 1
fi

log_info "Tailscale checks passed!"

# Clean previous K3s data
log_info "Pulizia automatica della directory dati K3s..."
rm -rf /var/lib/rancher/k3s

# Required parameters
K3S_TOKEN=${1:-""}
FIRST_MASTER_IP=${2:-""}

if [ -z "$K3S_TOKEN" ] || [ -z "$FIRST_MASTER_IP" ]; then
    log_error "K3S_TOKEN and FIRST_MASTER_IP are required!"
    log_error "Usage: $0 <K3S_TOKEN> <FIRST_MASTER_IP>"
    exit 1
fi

log_info "Starting K3s witness node installation..."

# Get Tailscale IP
TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "")
if [ -z "$TAILSCALE_IP" ]; then
    log_error "Tailscale not running or not connected!"
    log_error "Please install and configure Tailscale first"
    exit 1
fi

log_info "Tailscale IP: $TAILSCALE_IP"
log_info "First master IP: $FIRST_MASTER_IP"

# Check if Tailscale interface exists
if ! ip link show tailscale0 &>/dev/null; then
    log_error "Tailscale interface (tailscale0) not found!"
    exit 1
fi

# Install prerequisites
log_info "Installing prerequisites..."

# Detect OS
if [ -f /etc/debian_version ]; then
    log_info "Detected Debian/Ubuntu-based system"
    apt-get update
    apt-get install -y curl wget git vim htop
elif [ -f /etc/arch-release ]; then
    log_info "Detected Arch Linux system"
    pacman -Syu --noconfirm
    pacman -S --noconfirm curl wget git vim htop
else
    log_error "Unsupported OS"
    exit 1
fi

# Disable swap (required by Kubernetes)
log_info "Disabling swap..."
swapoff -a
sed -i '/ swap / s/^/#/' /etc/fstab

# Enable kernel modules
log_info "Configuring kernel modules..."
cat <<EOF | tee /etc/modules-load.d/k3s.conf
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

# Sysctl settings
log_info "Configuring sysctl..."
cat <<EOF | tee /etc/sysctl.d/k3s.conf
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF

sysctl --system

# Install K3s as witness (with NoSchedule taint)
log_info "Installing K3s as witness node (etcd-only)..."
log_info "This node will participate in consensus but NOT run workloads"
log_info "Using Tailscale IP: $TAILSCALE_IP"
log_info "Hostname: $HOSTNAME"

# IMPORTANTE: NON usare --bind-address con Tailscale
if ! curl -sfL https://get.k3s.io | K3S_TOKEN="$K3S_TOKEN" sh -s - server \
    --server "https://$FIRST_MASTER_IP:6443" \
    --node-ip="$TAILSCALE_IP" \
    --advertise-address="$TAILSCALE_IP" \
    --flannel-iface=tailscale0 \
    --write-kubeconfig-mode=644 \
    --disable=traefik \
    --disable=servicelb \
    --node-taint node-role.kubernetes.io/witness=true:NoSchedule \
    --tls-san="$TAILSCALE_IP" \
    --tls-san="$HOSTNAME" \
    --tls-san="localhost" \
    --tls-san="127.0.0.1"; then

    log_error "K3s installation script failed!"
    log_error ""
    log_error "=== DIAGNOSTICA POST-INSTALLAZIONE ==="
    log_error ""
    log_error "1. Stato del servizio k3s:"
    systemctl status k3s --no-pager || log_error "Servizio k3s non trovato"
    log_error ""
    log_error "2. Ultime righe del log k3s:"
    journalctl -u k3s --no-pager -n 100 || log_error "Nessun log k3s disponibile"
    log_error ""
    log_error "3. Verifica connettività al primo master ($FIRST_MASTER_IP):"
    ping -c 3 "$FIRST_MASTER_IP" || log_error "Ping failed!"
    log_error ""
    log_error "4. Verifica porta 6443 sul primo master:"
    timeout 5 bash -c "cat < /dev/null > /dev/tcp/$FIRST_MASTER_IP/6443" && log_error "Port 6443 is reachable" || log_error "Port 6443 is NOT reachable!"
    log_error ""
    log_error "5. Verifica interfacce di rete:"
    ip addr show tailscale0 || log_error "Tailscale interface not found!"
    log_error ""
    log_error "6. Verifica che il primo master sia raggiungibile via Tailscale:"
    tailscale status | grep "$FIRST_MASTER_IP" || log_error "Master not found in Tailscale network!"
    log_error ""
    log_error "SUGGERIMENTI:"
    log_error "- Verifica che il token K3S_TOKEN sia corretto e non scaduto"
    log_error "- Verifica che il primo master ($FIRST_MASTER_IP) sia online e K3s sia running"
    log_error "- Sul primo master esegui: systemctl status k3s"
    log_error "- Verifica la connettività Tailscale tra i nodi"
    log_error ""
    exit 1
fi

log_info "Waiting for K3s to start..."
sleep 30

# Verify installation
log_info "Verifying K3s installation..."
TIMEOUT=120
START_TIME=$(date +%s)
while [ $TIMEOUT -gt 0 ]; do
    if systemctl is-active --quiet k3s; then
        log_info "K3s service is running!"
        break
    fi
    sleep 2
    TIMEOUT=$((TIMEOUT-2))
done

if ! systemctl is-active --quiet k3s; then
    log_error "K3s service failed to start within 120 seconds!"
    log_error ""
    log_error "=== DIAGNOSTICA K3S ==="
    log_error ""
    log_error "1. Stato del servizio k3s:"
    systemctl status k3s --no-pager
    log_error ""
    log_error "2. Ultime righe del log k3s:"
    journalctl -u k3s --no-pager -n 50
    log_error ""
    log_error "3. Verifica certificati TLS generati:"
    if [ -d /var/lib/rancher/k3s/server/tls/ ]; then
        ls -la /var/lib/rancher/k3s/server/tls/
    else
        log_error "Directory TLS non trovata in /var/lib/rancher/k3s/server/tls/"
    fi
    log_error ""
    log_error "4. Verifica struttura directory K3s:"
    ls -la /var/lib/rancher/k3s/server/ 2>/dev/null || log_error "Directory server non trovata!"
    log_error ""
    log_error "5. Verifica network interfaces:"
    ip addr show tailscale0
    log_error ""
    log_error "6. Verifica connettività Tailscale:"
    tailscale status
    log_error ""
    log_error "7. Verifica connettività al primo master ($FIRST_MASTER_IP):"
    ping -c 3 "$FIRST_MASTER_IP" || log_error "Ping failed!"
    log_error ""
    log_error "8. Verifica porta 6443 sul primo master:"
    timeout 5 bash -c "cat < /dev/null > /dev/tcp/$FIRST_MASTER_IP/6443" && log_error "Port 6443 is reachable" || log_error "Port 6443 is NOT reachable!"
    log_error ""
    log_error "9. Verifica porte in ascolto locali:"
    ss -tulpn | grep -E ':(6443|2379|2380)' || log_error "Nessuna porta K3s in ascolto!"
    log_error ""
    log_error "10. Verifica se ci sono tentativi di connessione da altri nodi:"
    log_error "Ultimi 10 warning TLS dal log:"
    journalctl -u k3s --no-pager -n 100 | grep "bad certificate" | tail -10 | while read line; do
        echo "$line" | grep -oP 'remote-addr":"[^"]+' || true
    done
    log_error ""
    log_error "SUGGERIMENTI:"
    log_error "- Verifica che il token K3S_TOKEN sia corretto"
    log_error "- Verifica che FIRST_MASTER_IP ($FIRST_MASTER_IP) sia raggiungibile"
    log_error "- Verifica che il primo master sia in esecuzione: ssh $FIRST_MASTER_IP 'systemctl status k3s'"
    log_error ""
    exit 1
fi

# Check nodes
log_info "Cluster nodes:"
k3s kubectl get nodes

log_info ""
log_info "=========================================="
log_info "K3s Witness Node Installation Complete!"
log_info "Node IP: $TAILSCALE_IP"
log_info "Role: etcd consensus only (NoSchedule taint)"
log_info "=========================================="

# Create helper script for kubectl
cat > /usr/local/bin/k <<'EOF'
#!/bin/bash
k3s kubectl "$@"
EOF
chmod +x /usr/local/bin/k

log_info "Created shortcut: use 'k' instead of 'k3s kubectl'"
