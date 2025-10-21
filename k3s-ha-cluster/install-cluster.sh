#!/bin/bash
set -e

# K3s HA Cluster Interactive Installer
# This script guides you through installing a K3s HA cluster with Tailscale

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
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

log_step() {
    echo -e "${CYAN}[STEP]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

# Banner
clear
cat << "EOF"
╔═══════════════════════════════════════════════════════════╗
║                                                           ║
║      K3s High-Availability Cluster Installer              ║
║                                                           ║
║      Features:                                            ║
║      • 3-node etcd quorum (2 master + 1 witness)         ║
║      • Patroni PostgreSQL with zero data loss            ║
║      • Longhorn distributed storage                       ║
║      • Tailscale mesh VPN networking                      ║
║                                                           ║
╚═══════════════════════════════════════════════════════════╝
EOF
echo ""

# Check if Tailscale is installed locally
if ! command -v tailscale &> /dev/null; then
    log_error "Tailscale CLI is not installed on this machine!"
    log_error "Please install Tailscale CLI first: https://tailscale.com/download"
    exit 1
fi

# Check if sshpass is installed locally
if ! command -v sshpass &> /dev/null; then
    log_error "sshpass is not installed on this machine!"
    log_error "Please install sshpass:"
    log_error "  Debian/Ubuntu: apt-get install sshpass"
    log_error "  Arch Linux: pacman -S sshpass"
    log_error "  macOS: brew install hudochenkov/sshpass/sshpass"
    exit 1
fi

# Check if logged into Tailscale
if ! tailscale status &> /dev/null; then
    log_error "Tailscale is not running or not logged in!"
    log_error "Please run: tailscale up"
    exit 1
fi

log_info "Tailscale is running and connected!"
echo ""

# Get list of Tailscale devices
log_step "Fetching Tailscale devices..."
echo ""

DEVICES=$(tailscale status --json | jq -r '.Peer[] | "\(.HostName)|\(.TailscaleIPs[0])"')

if [ -z "$DEVICES" ]; then
    log_error "No Tailscale devices found in your network!"
    log_error "Please ensure other nodes are connected to Tailscale"
    exit 1
fi

# Display devices
echo -e "${BLUE}Available Tailscale devices:${NC}"
echo ""
echo "  #  | Hostname                | IP Address"
echo "-----+-------------------------+------------------"

declare -a DEVICE_LIST
i=1
while IFS='|' read -r hostname ip; do
    DEVICE_LIST[$i]="$hostname|$ip"
    printf "  %-2d | %-23s | %s\n" "$i" "$hostname" "$ip"
    ((i++))
done <<< "$DEVICES"

DEVICE_COUNT=$((i-1))
echo ""

# Ask which device to install on
while true; do
    read -p "$(echo -e ${CYAN}"Select device number (1-$DEVICE_COUNT): "${NC})" DEVICE_NUM
    if [[ "$DEVICE_NUM" =~ ^[0-9]+$ ]] && [ "$DEVICE_NUM" -ge 1 ] && [ "$DEVICE_NUM" -le "$DEVICE_COUNT" ]; then
        break
    else
        log_error "Invalid selection. Please enter a number between 1 and $DEVICE_COUNT"
    fi
done

SELECTED_DEVICE="${DEVICE_LIST[$DEVICE_NUM]}"
TARGET_HOSTNAME=$(echo "$SELECTED_DEVICE" | cut -d'|' -f1)
TARGET_IP=$(echo "$SELECTED_DEVICE" | cut -d'|' -f2)

echo ""
log_info "Selected device: $TARGET_HOSTNAME ($TARGET_IP)"
echo ""

# Ask if master or witness
echo -e "${BLUE}Node type:${NC}"
echo "  1) Master node (runs workloads)"
echo "  2) Witness node (etcd-only, no workloads)"
echo ""

while true; do
    read -p "$(echo -e ${CYAN}"Select node type (1-2): "${NC})" NODE_TYPE
    if [[ "$NODE_TYPE" == "1" ]] || [[ "$NODE_TYPE" == "2" ]]; then
        break
    else
        log_error "Invalid selection. Please enter 1 or 2"
    fi
done

if [ "$NODE_TYPE" == "1" ]; then
    NODE_TYPE_NAME="Master"
    INSTALL_SCRIPT="master/install-master.sh"
else
    NODE_TYPE_NAME="Witness"
    INSTALL_SCRIPT="witness/install-witness.sh"
fi

echo ""
log_info "Node type: $NODE_TYPE_NAME"
echo ""

# Ask for SSH credentials
# SSH login method selection
echo -e "${BLUE}SSH Connection Details:${NC}"
echo ""
while true; do
    read -p "$(echo -e ${CYAN}"Choose SSH login method: [1] Password [2] Certificate: "${NC})" SSH_LOGIN_METHOD
    if [[ "$SSH_LOGIN_METHOD" == "1" || "$SSH_LOGIN_METHOD" == "2" ]]; then
        break
    else
        log_error "Invalid selection. Please enter 1 or 2."
    fi
done

read -p "$(echo -e ${CYAN}"SSH username [root]: "${NC})" SSH_USER
SSH_USER=${SSH_USER:-root}

read -p "$(echo -e ${CYAN}"SSH port [22]: "${NC})" SSH_PORT
SSH_PORT=${SSH_PORT:-22}

if [ "$SSH_LOGIN_METHOD" == "1" ]; then
    echo ""
    read -s -p "$(echo -e ${CYAN}"SSH password: "${NC})" SSH_PASSWORD
    echo ""
    echo ""
    SSH_CERT_PATH=""
else
    echo ""
    read -p "$(echo -e ${CYAN}"Path to private key [~/.ssh/id_rsa]: "${NC})" SSH_CERT_PATH
    SSH_CERT_PATH=${SSH_CERT_PATH:-~/.ssh/id_rsa}
    SSH_PASSWORD=""
fi

# Test SSH connection
log_step "Testing SSH connection to $TARGET_HOSTNAME..."

# Costruisci comando SSH/SCP in base al metodo scelto
if [ "$SSH_LOGIN_METHOD" == "1" ]; then
    # Password
    if ! command -v sshpass &> /dev/null; then
        log_error "sshpass is not installed!"
        log_error "Please install it o use certificate-based authentication"
        log_error "  Debian/Ubuntu: apt-get install sshpass"
        log_error "  Arch Linux: pacman -S sshpass"
        log_error "  macOS: brew install hudochenkov/sshpass/sshpass"
        exit 1
    fi
    SSH_CMD="sshpass -p '$SSH_PASSWORD' ssh -o StrictHostKeyChecking=no -p $SSH_PORT $SSH_USER@$TARGET_IP"
    SCP_CMD="sshpass -p '$SSH_PASSWORD' scp -P $SSH_PORT"
elif [ "$SSH_LOGIN_METHOD" == "2" ]; then
    # Certificato
    SSH_CMD="ssh -i $SSH_CERT_PATH -o StrictHostKeyChecking=no -p $SSH_PORT $SSH_USER@$TARGET_IP"
    SCP_CMD="scp -i $SSH_CERT_PATH -P $SSH_PORT"
fi

# Verifica che l'utente sia sudoer
log_step "Verifying sudo privileges for $SSH_USER on $TARGET_HOSTNAME..."
if ! eval "$SSH_CMD 'sudo -l >/dev/null 2>&1'"; then
    log_error "User $SSH_USER does not have sudo privileges on $TARGET_HOSTNAME!"
    log_error "Please ensure the user is in the sudoers file."
    exit 1
fi
log_success "$SSH_USER is a sudoer on $TARGET_HOSTNAME."
echo ""

# For master nodes, ask if first or joining
FIRST_MASTER="yes"
K3S_TOKEN=""
FIRST_MASTER_IP=""

if [ "$NODE_TYPE" == "1" ]; then
    echo -e "${BLUE}Master node configuration:${NC}"
    echo "  1) First master (initialize cluster)"
    echo "  2) Additional master (join existing cluster)"
    echo ""

    while true; do
        read -p "$(echo -e ${CYAN}"Select (1-2): "${NC})" MASTER_TYPE
        if [[ "$MASTER_TYPE" == "1" ]] || [[ "$MASTER_TYPE" == "2" ]]; then
            break
        else
            log_error "Invalid selection. Please enter 1 or 2"
        fi
    done

    if [ "$MASTER_TYPE" == "2" ]; then
        FIRST_MASTER="no"
        echo ""
        read -p "$(echo -e ${CYAN}"Enter K3s token from first master: "${NC})" K3S_TOKEN
        read -p "$(echo -e ${CYAN}"Enter first master Tailscale IP: "${NC})" FIRST_MASTER_IP
    fi
fi

# For witness, we need token and first master IP
if [ "$NODE_TYPE" == "2" ]; then
    echo ""
    read -p "$(echo -e ${CYAN}"Enter K3s token from first master: "${NC})" K3S_TOKEN
    read -p "$(echo -e ${CYAN}"Enter first master Tailscale IP: "${NC})" FIRST_MASTER_IP
fi

# Ask for storage directory
echo ""
read -p "$(echo -e ${CYAN}"Storage directory [/mnt/k3s-storage]: "${NC})" STORAGE_DIR
STORAGE_DIR=${STORAGE_DIR:-/mnt/k3s-storage}

# Summary
echo ""
echo "=========================================="
log_info "Installation Summary:"
echo "=========================================="
echo "  Target Host:     $TARGET_HOSTNAME"
echo "  Target IP:       $TARGET_IP"
echo "  Node Type:       $NODE_TYPE_NAME"
if [ "$NODE_TYPE" == "1" ]; then
    if [ "$FIRST_MASTER" == "yes" ]; then
        echo "  Master Type:     First master (cluster init)"
    else
        echo "  Master Type:     Additional master (joining)"
        echo "  First Master IP: $FIRST_MASTER_IP"
    fi
fi
echo "  SSH User:        $SSH_USER"
echo "  SSH Port:        $SSH_PORT"
echo "  Storage Dir:     $STORAGE_DIR"
echo "=========================================="
echo ""

read -p "$(echo -e ${YELLOW}"Proceed with installation? (yes/no): "${NC})" CONFIRM
if [ "$CONFIRM" != "yes" ]; then
    log_info "Installation cancelled"
    exit 0
fi

echo ""
log_step "Starting installation..."
echo ""

# Get script directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"




# Copy installation script to target
log_info "Copying installation script to target..."
SCP_COMMAND="$SCP_CMD $SCRIPT_DIR/$INSTALL_SCRIPT $SSH_USER@$TARGET_IP:/tmp/install-k3s.sh"
log_info "Comando SCP usato: $SCP_COMMAND"
SCP_OUTPUT=$(eval "$SCP_COMMAND" 2>&1) || {
    log_error "Failed to copy installation script via SCP!"
    echo "$SCP_OUTPUT"
    log_error "Possibili cause:"
    log_error "- Password errata o chiave non autorizzata"
    log_error "- Permessi insufficienti sull'utente remoto"
    log_error "- SSH disabilitato o configurazione restrittiva"
    log_error "Suggerimenti:"
    log_error "- Verifica username, password o path della chiave"
    log_error "- Assicurati che la chiave sia presente in ~/.ssh/authorized_keys sul server remoto"
    log_error "- Prova a collegarti manualmente con lo stesso comando SCP/SSH per vedere l'errore dettagliato"
    exit 1
}

# Make script executable
log_info "Comando SSH usato: $SSH_CMD 'sudo chmod +x /tmp/install-k3s.sh'"
CHMOD_OUTPUT=$(eval "$SSH_CMD 'sudo chmod +x /tmp/install-k3s.sh'" 2>&1) || {
    log_error "Failed to set executable permission on remote script!"
    echo "$CHMOD_OUTPUT"
    exit 1
}

# Run installation
log_info "Running installation on $TARGET_HOSTNAME..."
echo ""

if [ "$NODE_TYPE" == "1" ]; then
    # Master node
    if [ "$FIRST_MASTER" == "yes" ]; then
        eval "$SSH_CMD 'cd /tmp && sudo ./install-k3s.sh yes \"\" \"\" \"$STORAGE_DIR\"'" || {
            log_error "Installation failed!"
            exit 1
        }
    else
        eval "$SSH_CMD 'cd /tmp && sudo ./install-k3s.sh no \"$K3S_TOKEN\" \"$FIRST_MASTER_IP\" \"$STORAGE_DIR\"'" || {
            log_error "Installation failed!"
            exit 1
        }
    fi
else
    # Witness node
    eval "$SSH_CMD 'cd /tmp && sudo ./install-k3s.sh \"$K3S_TOKEN\" \"$FIRST_MASTER_IP\"'" || {
        log_error "Installation failed!"
        exit 1
    }
fi

echo ""
log_success "Installation completed successfully!"
echo ""

# If first master, get token
if [ "$NODE_TYPE" == "1" ] && [ "$FIRST_MASTER" == "yes" ]; then
    echo "=========================================="
    log_info "IMPORTANT: Save this K3s token for other nodes!"
    echo "=========================================="
    K3S_TOKEN=$(eval "$SSH_CMD 'cat /var/lib/rancher/k3s/server/node-token'")
    echo ""
    echo "$K3S_TOKEN"
    echo ""
    echo "=========================================="
    echo ""

    # Save to local file
    echo "$K3S_TOKEN" > "$SCRIPT_DIR/k3s-token.txt"
    log_info "Token also saved to: $SCRIPT_DIR/k3s-token.txt"
    echo ""
fi

# Next steps
echo ""
log_info "Next steps:"
echo ""

if [ "$NODE_TYPE" == "1" ] && [ "$FIRST_MASTER" == "yes" ]; then
    echo "  1. Install second master node using this script"
    echo "  2. Install witness node using this script"
    echo "  3. Deploy cluster services:"
    echo "     cd $SCRIPT_DIR"
    echo "     ./scripts/deploy-longhorn.sh"
    echo "     ./scripts/deploy-database.sh"
    echo "     ./scripts/deploy-apps.sh"
    echo ""
elif [ "$NODE_TYPE" == "1" ]; then
    echo "  • If you have another master to add, run this script again"
    echo "  • Install witness node if not done yet"
    echo "  • Once all nodes are installed, deploy cluster services"
    echo ""
else
    echo "  • Your 3-node cluster is now ready!"
    echo "  • Deploy cluster services using the scripts in $SCRIPT_DIR/scripts/"
    echo ""
fi

log_success "All done!"
