#!/bin/bash
set -e

# K3s Master Node Installation Script
# This script installs K3s on a master node with HA configuration

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


# Funzione per rimuovere questo nodo da un eventuale cluster remoto
remove_from_cluster() {
    local node_name=$(hostname)

    # Verifica se K3s è installato e ha un kubeconfig
    if [ -f /etc/rancher/k3s/k3s.yaml ]; then
        log_info "Rilevata installazione K3s esistente, verifico se il nodo è parte di un cluster..."

        # Prova a ottenere informazioni sul cluster
        export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

        # Verifica se questo è un nodo standalone o parte di un cluster
        if timeout 5 kubectl get nodes &>/dev/null; then
            local node_count=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)

            if [ "$node_count" -gt 1 ]; then
                log_warn "Questo nodo fa parte di un cluster con $node_count nodi"
                log_info "Tentativo di rimuovere questo nodo ($node_name) dal cluster..."

                # Drain del nodo (ignora errori se il nodo è già down)
                kubectl drain "$node_name" --ignore-daemonsets --delete-emptydir-data --force --timeout=30s 2>/dev/null || log_warn "Drain fallito o non necessario"

                # Delete del nodo
                if kubectl delete node "$node_name" 2>/dev/null; then
                    log_info "Nodo rimosso dal cluster con successo"
                    sleep 3
                else
                    log_warn "Non è stato possibile rimuovere il nodo dal cluster (potrebbe essere già stato rimosso)"
                fi
            else
                log_info "Questo è un nodo standalone, nessuna rimozione dal cluster necessaria"
            fi
        else
            log_info "Non è possibile connettersi al cluster (potrebbe essere già stato rimosso o essere offline)"
        fi

        unset KUBECONFIG
    fi
}

# Funzione di pulizia K3s
clean_k3s() {
    log_warn "Eseguo pulizia completa di K3s (stop, uninstall, rimozione file, variabili d'ambiente e directory residue)"

    # Prima rimuovi il nodo da un eventuale cluster
    remove_from_cluster

    # Poi procedi con la pulizia locale
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

# Detect if this is the first master or joining master
FIRST_MASTER=${1:-"yes"}
K3S_TOKEN=${2:-""}
FIRST_MASTER_IP=${3:-""}
STORAGE_DIR=${4:-"/mnt/k3s-storage"}

log_info "Starting K3s master node installation..."
log_info "First master: $FIRST_MASTER"

# Get Tailscale IP
TAILSCALE_IP=$(tailscale ip -4 2>/dev/null || echo "")
if [ -z "$TAILSCALE_IP" ]; then
    log_error "Tailscale not running or not connected!"
    log_error "Please install and configure Tailscale first"
    exit 1
fi

log_info "Tailscale IP: $TAILSCALE_IP"

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
    apt-get install -y curl wget git vim htop open-iscsi nfs-common
    systemctl enable --now iscsid
elif [ -f /etc/arch-release ]; then
    log_info "Detected Arch Linux system"
    pacman -Syu --noconfirm
    pacman -S --noconfirm curl wget git vim htop open-iscsi nfs-utils
    systemctl enable --now iscsid
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

# Create storage directory
log_info "Creating storage directory: $STORAGE_DIR"
mkdir -p "$STORAGE_DIR"

# Install K3s
if [ "$FIRST_MASTER" = "yes" ]; then
    log_info "Installing K3s as FIRST master node..."
    log_info "Using Tailscale IP: $TAILSCALE_IP"
    log_info "Hostname: $HOSTNAME"

    # IMPORTANTE: NON usare --bind-address con Tailscale per evitare problemi con etcd
    # etcd ha bisogno di fare bind su 0.0.0.0 per funzionare correttamente con --cluster-init
    curl -sfL https://get.k3s.io | sh -s - server \
        --cluster-init \
        --node-ip="$TAILSCALE_IP" \
        --advertise-address="$TAILSCALE_IP" \
        --flannel-iface=tailscale0 \
        --write-kubeconfig-mode=644 \
        --disable=traefik \
        --disable=servicelb \
        --data-dir="$STORAGE_DIR/k3s" \
        --tls-san="$TAILSCALE_IP" \
        --tls-san="$HOSTNAME" \
        --tls-san="localhost" \
        --tls-san="127.0.0.1"


    log_info "Waiting for K3s to start and generate node-token..."
    TIMEOUT=120
    TOKEN_PATH="$STORAGE_DIR/k3s/server/token"
    while [ $TIMEOUT -gt 0 ]; do
        if [ -f "$TOKEN_PATH" ]; then
            log_info "node-token generated successfully at $TOKEN_PATH!"
            break
        fi
        sleep 2
        TIMEOUT=$((TIMEOUT-2))
    done

    if [ ! -f "$TOKEN_PATH" ]; then
        log_error "K3s non ha generato il file node-token entro 120 secondi!"
        log_error ""
        log_error "=== DIAGNOSTICA K3S ==="
        log_error ""
        log_error "1. Stato del servizio k3s:"
        systemctl status k3s --no-pager
        log_error ""
        log_error "2. Ultime righe del log k3s:"
        journalctl -u k3s --no-pager -n 50
        log_error ""
        log_error "3. Verifica certificati TLS generati (in $STORAGE_DIR):"
        if [ -d "$STORAGE_DIR/k3s/server/tls/" ]; then
            ls -la "$STORAGE_DIR/k3s/server/tls/"
        else
            log_error "Directory TLS non trovata in $STORAGE_DIR/k3s/server/tls/"
        fi
        log_error ""
        log_error "4. Verifica struttura directory K3s:"
        ls -la "$STORAGE_DIR/k3s/server/" 2>/dev/null || log_error "Directory server non trovata in $STORAGE_DIR/k3s/server/"
        log_error ""
        log_error "5. Verifica network interfaces:"
        ip addr show tailscale0
        log_error ""
        log_error "6. Verifica connettività Tailscale:"
        tailscale status
        log_error ""
        log_error "7. Verifica porte in ascolto:"
        ss -tulpn | grep -E ':(6443|2379|2380)'
        log_error ""
        log_error "8. Verifica se ci sono tentativi di connessione da altri nodi:"
        log_error "Ultimi 10 warning TLS dal log:"
        journalctl -u k3s --no-pager -n 100 | grep "bad certificate" | tail -10 | while read line; do
            echo "$line" | grep -oP 'remote-addr":"[^"]+' || true
        done
        log_error ""
        log_error "ATTENZIONE: Se vedi connessioni da altri IP Tailscale,"
        log_error "assicurati di fermare K3s su TUTTI gli altri nodi prima di riavviare questo!"
        log_error "Su ogni altro nodo esegui: sudo systemctl stop k3s"
        log_error ""
        exit 1
    fi

    # Verifica che etcd sia effettivamente funzionante
    log_info "Verifying etcd cluster health..."
    sleep 5
    if ! k3s kubectl get nodes &>/dev/null; then
        log_warn "kubectl non risponde immediatamente, attendo ancora..."
        sleep 10
    fi

    # Get and display token
    K3S_TOKEN=$(cat "$TOKEN_PATH")
    log_info "K3s installation complete!"
    echo ""
    log_info "=========================================="
    log_info "SAVE THIS TOKEN FOR OTHER NODES:"
    echo ""
    echo "$K3S_TOKEN"
    echo ""
    log_info "=========================================="
    echo ""

    # Save token to file
    echo "$K3S_TOKEN" > /root/k3s-token.txt
    log_info "Token also saved to: /root/k3s-token.txt"

else
    log_info "Installing K3s as ADDITIONAL master node..."

    if [ -z "$K3S_TOKEN" ] || [ -z "$FIRST_MASTER_IP" ]; then
        log_error "For joining master, K3S_TOKEN and FIRST_MASTER_IP are required!"
        log_error "Usage: $0 no <K3S_TOKEN> <FIRST_MASTER_IP> [STORAGE_DIR]"
        exit 1
    fi

    log_info "Joining cluster at: https://$FIRST_MASTER_IP:6443"
    log_info "Using Tailscale IP: $TAILSCALE_IP"
    log_info "Hostname: $HOSTNAME"

    # IMPORTANTE: NON usare --bind-address con Tailscale
    curl -sfL https://get.k3s.io | K3S_TOKEN="$K3S_TOKEN" sh -s - server \
        --server "https://$FIRST_MASTER_IP:6443" \
        --node-ip="$TAILSCALE_IP" \
        --advertise-address="$TAILSCALE_IP" \
        --flannel-iface=tailscale0 \
        --write-kubeconfig-mode=644 \
        --disable=traefik \
        --disable=servicelb \
        --data-dir="$STORAGE_DIR/k3s" \
        --tls-san="$TAILSCALE_IP" \
        --tls-san="$HOSTNAME" \
        --tls-san="localhost" \
        --tls-san="127.0.0.1"

    log_info "Waiting for K3s to start..."
    sleep 30
fi

# Verify installation
log_info "Verifying K3s installation..."
if systemctl is-active --quiet k3s; then
    log_info "K3s service is running!"
else
    log_error "K3s service is not running!"
    systemctl status k3s
    exit 1
fi

# Check nodes
log_info "Cluster nodes:"
k3s kubectl get nodes

log_info ""
log_info "=========================================="
log_info "K3s Master Installation Complete!"
log_info "Node IP: $TAILSCALE_IP"
log_info "Kubeconfig: /etc/rancher/k3s/k3s.yaml"
log_info "=========================================="

# Configure kubectl for root user
log_info "Configuring kubectl for root user..."
mkdir -p /root/.kube
cp /etc/rancher/k3s/k3s.yaml /root/.kube/config
chown root:root /root/.kube/config
chmod 600 /root/.kube/config

# Set KUBECONFIG environment variable persistently
if ! grep -q "KUBECONFIG" /root/.bashrc; then
    echo 'export KUBECONFIG=/root/.kube/config' >> /root/.bashrc
fi

if [ -f /root/.zshrc ]; then
    if ! grep -q "KUBECONFIG" /root/.zshrc; then
        echo 'export KUBECONFIG=/root/.kube/config' >> /root/.zshrc
    fi
fi

# Set for current session
export KUBECONFIG=/root/.kube/config

log_info "kubectl configured successfully!"
log_info "KUBECONFIG set to: /root/.kube/config"

# Create helper script for kubectl
cat > /usr/local/bin/k <<'EOF'
#!/bin/bash
k3s kubectl "$@"
EOF
chmod +x /usr/local/bin/k

log_info "Created shortcut: use 'k' instead of 'k3s kubectl'"
log_info ""
log_info "You can now use 'kubectl' command directly (after re-login)"
log_info "Or use 'k' as a shortcut immediately"
