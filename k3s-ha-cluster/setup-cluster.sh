#!/bin/bash

# K3s HA Cluster Setup Script
# This script automates the complete setup of a K3s HA cluster with Tailscale networking

set -e

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
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
    echo -e "${BLUE}[STEP]${NC} $1"
}

# Function to ask yes/no questions
ask_yes_no() {
    local prompt="$1"
    local default="${2:-n}"
    local response

    if [ "$default" = "y" ]; then
        prompt="$prompt [Y/n]: "
    else
        prompt="$prompt [y/N]: "
    fi

    while true; do
        read -p "$prompt" response
        response=${response:-$default}
        case "$response" in
            [Yy]*) return 0 ;;
            [Nn]*) return 1 ;;
            *) echo "Please answer yes or no." ;;
        esac
    done
}

# Function to validate IP address
validate_ip() {
    local ip=$1
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        local IFS='.'
        local -a octets=($ip)
        [[ ${octets[0]} -le 255 && ${octets[1]} -le 255 && ${octets[2]} -le 255 && ${octets[3]} -le 255 ]]
        return $?
    fi
    return 1
}

# Function to validate hostname
validate_hostname() {
    local hostname=$1

    # First check if it's a valid IP address
    if validate_ip "$hostname"; then
        return 0
    fi

    # Check for valid hostname/FQDN (including .local domains)
    # Hostname can contain alphanumeric, hyphens, dots
    # Each label must start and end with alphanumeric
    # Minimum one character, maximum 253 characters total
    if [[ $hostname =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?)*$ ]] && [ ${#hostname} -le 253 ]; then
        return 0
    fi

    return 1
}

# Function to validate domain name
validate_domain() {
    local domain=$1
    if [[ $domain =~ ^([a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
        return 0
    fi
    return 1
}

# Function to test SSH connection
test_ssh_connection() {
    local host=$1
    local user=$2
    local key=$3

    if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no -i "$key" "${user}@${host}" "echo 'SSH connection successful'" &>/dev/null; then
        return 0
    fi
    return 1
}

# Banner
clear
echo -e "${BLUE}╔═══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║                                                           ║${NC}"
echo -e "${BLUE}║         K3s HA Cluster Setup Script                       ║${NC}"
echo -e "${BLUE}║         Automated cluster deployment with Tailscale       ║${NC}"
echo -e "${BLUE}║                                                           ║${NC}"
echo -e "${BLUE}╚═══════════════════════════════════════════════════════════╝${NC}"
echo ""

# Check if running on a Unix-like system
if [[ "$OSTYPE" != "linux-gnu"* && "$OSTYPE" != "darwin"* ]]; then
    log_error "This script must be run on Linux or macOS"
    exit 1
fi

# Check required tools
log_step "Checking required tools..."
REQUIRED_TOOLS=("ssh" "ssh-keygen" "ssh-copy-id")
for tool in "${REQUIRED_TOOLS[@]}"; do
    if ! command -v "$tool" &> /dev/null; then
        log_error "Required tool '$tool' is not installed"
        exit 1
    fi
done
log_info "All required tools are available"
echo ""

# =============================================================================
# STEP 1: Domain Configuration
# =============================================================================
log_step "STEP 1: Domain Configuration"
echo ""

DOMAIN_TYPE=""
DOMAIN=""
CLOUDFLARE_API_KEY=""

if ask_yes_no "Do you want to use a real domain with Cloudflare DNS?" "n"; then
    DOMAIN_TYPE="real"

    while true; do
        read -p "Enter your domain name (e.g., example.com): " DOMAIN
        if validate_domain "$DOMAIN"; then
            log_info "Domain: $DOMAIN"
            break
        else
            log_error "Invalid domain name format"
        fi
    done

    read -sp "Enter your Cloudflare API Token Key (can be found in your Cloudflare dashboard at url https://dash.cloudflare.com/profile/api-tokens): " CLOUDFLARE_API_KEY
    echo ""
    if [ -z "$CLOUDFLARE_API_KEY" ]; then
        log_error "Cloudflare API Token Key cannot be empty"
        exit 1
    fi
    log_info "Cloudflare API Token Key saved"
else
    DOMAIN_TYPE="local"

    read -p "Enter your local domain name (e.g., mycluster.local) [default: k3s.local]: " DOMAIN
    DOMAIN=${DOMAIN:-k3s.local}
    log_info "Local domain: $DOMAIN"
fi
echo ""

# =============================================================================
# STEP 2: SSH Key Generation
# =============================================================================
log_step "STEP 2: SSH Key Generation"
echo ""

DEFAULT_KEY_PATH="$HOME/.ssh/cluster.${DOMAIN}"
read -p "Enter SSH key path [default: $DEFAULT_KEY_PATH]: " SSH_KEY_PATH
SSH_KEY_PATH=${SSH_KEY_PATH:-$DEFAULT_KEY_PATH}

# Expand tilde to home directory
SSH_KEY_PATH="${SSH_KEY_PATH/#\~/$HOME}"

# Check if key already exists
if [ -f "$SSH_KEY_PATH" ] || [ -f "${SSH_KEY_PATH}.pub" ]; then
    log_warn "SSH key already exists at $SSH_KEY_PATH"
    if ask_yes_no "Do you want to overwrite it?" "n"; then
        rm -f "$SSH_KEY_PATH" "${SSH_KEY_PATH}.pub"
        log_info "Existing key removed"
    else
        log_info "Using existing key"
    fi
fi

if [ ! -f "$SSH_KEY_PATH" ]; then
    log_info "Generating SSH key pair without passphrase..."
    mkdir -p "$(dirname "$SSH_KEY_PATH")"
    ssh-keygen -t ed25519 -f "$SSH_KEY_PATH" -N "" -C "k3s-cluster-${DOMAIN}"
    log_info "SSH key generated: $SSH_KEY_PATH"
fi

# Set correct permissions
chmod 600 "$SSH_KEY_PATH"
chmod 644 "${SSH_KEY_PATH}.pub"
echo ""

# =============================================================================
# STEP 3: Cluster Node Configuration
# =============================================================================
log_step "STEP 3: Cluster Node Configuration"
echo ""

log_info "K3s HA Cluster Node Configuration"
log_info "  - Minimum: 1 node (single node cluster)"
log_info "  - Recommended: 3+ nodes (HA with etcd quorum)"
log_info "  - For HA: Use odd number of nodes (3, 5, 7, etc.)"
echo ""

# Ask for number of nodes
while true; do
    read -p "How many nodes do you want in the cluster? [default: 3]: " NUM_NODES
    NUM_NODES=${NUM_NODES:-3}

    if [[ "$NUM_NODES" =~ ^[0-9]+$ ]] && [ "$NUM_NODES" -ge 1 ]; then
        if [ "$NUM_NODES" -eq 1 ]; then
            log_warn "Single node cluster - no high availability"
        elif [ "$NUM_NODES" -eq 2 ]; then
            log_warn "2-node cluster is not recommended (cannot achieve quorum if one node fails)"
            if ! ask_yes_no "Continue with 2 nodes?" "n"; then
                continue
            fi
        elif [ $((NUM_NODES % 2)) -eq 0 ]; then
            log_warn "Even number of nodes - consider using odd number for better HA"
            if ! ask_yes_no "Continue with $NUM_NODES nodes?" "y"; then
                continue
            fi
        fi
        log_info "Configuring cluster with $NUM_NODES node(s)"
        break
    else
        log_error "Please enter a valid number (minimum 1)"
    fi
done
echo ""

declare -a NODE_HOSTS
declare -a NODE_NAMES
declare -a NODE_ROLES  # master, worker, or witness

for i in $(seq 1 $NUM_NODES); do
    NODE_TYPE="Node $i"
    NODE_ROLE="master"  # Default role

    # For multi-node clusters, ask for role
    if [ "$NUM_NODES" -gt 1 ]; then
        if [ "$i" -eq 1 ]; then
            NODE_TYPE="Node $i (First Control Plane)"
            NODE_ROLE="master"
        else
            echo "Node $i role:"
            echo "  1) Control Plane (master/etcd)"
            echo "  2) Worker (no etcd, for workloads only)"
            echo "  3) Witness (etcd only, no workloads)"

            while true; do
                read -p "Select role [1-3, default: 1]: " ROLE_CHOICE
                ROLE_CHOICE=${ROLE_CHOICE:-1}

                case $ROLE_CHOICE in
                    1)
                        NODE_ROLE="master"
                        NODE_TYPE="Node $i (Control Plane)"
                        break
                        ;;
                    2)
                        NODE_ROLE="worker"
                        NODE_TYPE="Node $i (Worker)"
                        break
                        ;;
                    3)
                        NODE_ROLE="witness"
                        NODE_TYPE="Node $i (Witness)"
                        break
                        ;;
                    *)
                        log_error "Invalid choice. Please select 1, 2, or 3"
                        ;;
                esac
            done
        fi
    fi

    while true; do
        read -p "Enter IP address or hostname for $NODE_TYPE: " NODE_HOST
        if validate_hostname "$NODE_HOST"; then
            NODE_HOSTS+=("$NODE_HOST")
            log_info "$NODE_TYPE address: $NODE_HOST"
            break
        else
            log_error "Invalid IP address or hostname format"
        fi
    done

    read -p "Enter friendly hostname for $NODE_TYPE [default: node$i]: " NODE_NAME
    NODE_NAME=${NODE_NAME:-node$i}
    NODE_NAMES+=("$NODE_NAME")
    NODE_ROLES+=("$NODE_ROLE")
    log_info "$NODE_TYPE hostname: $NODE_NAME (role: $NODE_ROLE)"
    echo ""
done

# =============================================================================
# STEP 4: Cluster Admin User Configuration
# =============================================================================
log_step "STEP 4: Cluster Admin User Configuration"
echo ""

read -p "Enter username for cluster admin [default: cluster_admin]: " CLUSTER_ADMIN_USER
CLUSTER_ADMIN_USER=${CLUSTER_ADMIN_USER:-cluster_admin}
log_info "Cluster admin user: $CLUSTER_ADMIN_USER"
echo ""

# =============================================================================
# STEP 5: Initial SSH Access Configuration (Per Node)
# =============================================================================
log_step "STEP 5: Initial SSH Access Configuration"
echo ""

log_info "To set up the cluster nodes, we need initial SSH access to each node"
log_info "Each node may have different credentials"
echo ""

declare -a NODE_SSH_USERS
declare -a NODE_SSH_AUTH_METHODS
declare -a NODE_SSH_PASSWORDS
declare -a NODE_SSH_KEYS

for i in $(seq 0 $((NUM_NODES - 1))); do
    NODE_HOST="${NODE_HOSTS[$i]}"
    NODE_NAME="${NODE_NAMES[$i]}"
    NODE_NUM=$((i + 1))

    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Node $NODE_NUM: $NODE_NAME ($NODE_HOST)"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    read -p "Enter SSH username (sudoer) for $NODE_NAME: " NODE_SSH_USER
    NODE_SSH_USERS+=("$NODE_SSH_USER")

    if ask_yes_no "Use SSH key for authentication? (no = password)" "y"; then
        NODE_SSH_AUTH_METHODS+=("key")
        read -p "Enter path to SSH private key for $NODE_NAME: " NODE_SSH_KEY
        NODE_SSH_KEY="${NODE_SSH_KEY/#\~/$HOME}"

        if [ ! -f "$NODE_SSH_KEY" ]; then
            log_error "SSH key file not found: $NODE_SSH_KEY"
            exit 1
        fi
        NODE_SSH_KEYS+=("$NODE_SSH_KEY")
        NODE_SSH_PASSWORDS+=("")  # Empty password for key auth
        log_info "Using SSH key: $NODE_SSH_KEY"
    else
        NODE_SSH_AUTH_METHODS+=("password")
        read -sp "Enter SSH password for $NODE_NAME: " NODE_SSH_PASSWORD
        echo ""
        NODE_SSH_PASSWORDS+=("$NODE_SSH_PASSWORD")
        NODE_SSH_KEYS+=("")  # Empty key for password auth
        log_info "Using password authentication"
    fi
    echo ""
done

# =============================================================================
# STEP 6: Deploy to Cluster Nodes
# =============================================================================
log_step "STEP 6: Deploying to Cluster Nodes"
echo ""

# Function to execute command on remote node
exec_remote() {
    local node_idx=$1
    local host=$2
    local user=$3
    shift 3
    local cmd="$*"

    local auth_method="${NODE_SSH_AUTH_METHODS[$node_idx]}"
    local ssh_key="${NODE_SSH_KEYS[$node_idx]}"
    local ssh_password="${NODE_SSH_PASSWORDS[$node_idx]}"

    if [ "$auth_method" = "key" ]; then
        ssh -o StrictHostKeyChecking=no -i "$ssh_key" "${user}@${host}" "$cmd"
    else
        sshpass -p "$ssh_password" ssh -o StrictHostKeyChecking=no "${user}@${host}" "$cmd"
    fi
}

# Function to copy file to remote node
copy_remote() {
    local node_idx=$1
    local host=$2
    local user=$3
    local src=$4
    local dst=$5

    local auth_method="${NODE_SSH_AUTH_METHODS[$node_idx]}"
    local ssh_key="${NODE_SSH_KEYS[$node_idx]}"
    local ssh_password="${NODE_SSH_PASSWORDS[$node_idx]}"

    if [ "$auth_method" = "key" ]; then
        scp -o StrictHostKeyChecking=no -i "$ssh_key" "$src" "${user}@${host}:${dst}"
    else
        sshpass -p "$ssh_password" scp -o StrictHostKeyChecking=no "$src" "${user}@${host}:${dst}"
    fi
}

# Install sshpass if any node uses password authentication
NEEDS_SSHPASS=false
for auth_method in "${NODE_SSH_AUTH_METHODS[@]}"; do
    if [ "$auth_method" = "password" ]; then
        NEEDS_SSHPASS=true
        break
    fi
done

if [ "$NEEDS_SSHPASS" = true ]; then
    if ! command -v sshpass &> /dev/null; then
        log_warn "sshpass is not installed. Attempting to install..."
        if [[ "$OSTYPE" == "darwin"* ]]; then
            if command -v brew &> /dev/null; then
                brew install hudochenkov/sshpass/sshpass
            else
                log_error "Homebrew is not installed. Cannot install sshpass."
                log_error "Please install sshpass manually or use SSH key authentication"
                exit 1
            fi
        elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
            if command -v apt-get &> /dev/null; then
                sudo apt-get update && sudo apt-get install -y sshpass
            elif command -v yum &> /dev/null; then
                sudo yum install -y sshpass
            elif command -v pacman &> /dev/null; then
                sudo pacman -S --noconfirm sshpass
            else
                log_error "Cannot install sshpass. Please install it manually"
                exit 1
            fi
        fi
    fi
fi

# Process each node
for i in $(seq 0 $((NUM_NODES - 1))); do
    NODE_HOST="${NODE_HOSTS[$i]}"
    NODE_NAME="${NODE_NAMES[$i]}"
    NODE_SSH_USER="${NODE_SSH_USERS[$i]}"
    NODE_NUM=$((i + 1))

    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Processing Node $NODE_NUM: $NODE_NAME ($NODE_HOST)"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Test initial connection
    log_info "Testing initial SSH connection to $NODE_HOST..."
    if ! exec_remote "$i" "$NODE_HOST" "$NODE_SSH_USER" "echo 'Connection successful'" &>/dev/null; then
        log_error "Cannot connect to $NODE_HOST with provided credentials"
        exit 1
    fi
    log_info "Initial connection successful"

    # Check if sudo is installed
    log_info "Checking if sudo is installed..."
    if ! exec_remote "$i" "$NODE_HOST" "$NODE_SSH_USER" "command -v sudo" &>/dev/null; then
        log_warn "sudo is not installed on $NODE_HOST"
        log_info "Installing sudo..."

        # Detect OS and install sudo
        exec_remote "$i" "$NODE_HOST" "$NODE_SSH_USER" "
            if [ -f /etc/debian_version ]; then
                su -c 'apt-get update && apt-get install -y sudo'
            elif [ -f /etc/redhat-release ]; then
                su -c 'yum install -y sudo'
            elif [ -f /etc/arch-release ]; then
                su -c 'pacman -S --noconfirm sudo'
            else
                echo 'Unsupported OS'
                exit 1
            fi
        "
        log_info "sudo installed successfully"
    else
        log_info "sudo is already installed"
    fi

    # Check if user already exists
    log_info "Checking if user $CLUSTER_ADMIN_USER exists..."
    if exec_remote "$i" "$NODE_HOST" "$NODE_SSH_USER" "id $CLUSTER_ADMIN_USER" &>/dev/null; then
        log_warn "User $CLUSTER_ADMIN_USER already exists on $NODE_HOST"
        if ask_yes_no "Do you want to reconfigure this user?" "y"; then
            log_info "Reconfiguring user $CLUSTER_ADMIN_USER..."
        else
            log_info "Skipping user creation for $NODE_HOST"
            continue
        fi
    else
        log_info "Creating user $CLUSTER_ADMIN_USER..."
        exec_remote "$i" "$NODE_HOST" "$NODE_SSH_USER" "
            sudo useradd -m -s /bin/bash $CLUSTER_ADMIN_USER 2>/dev/null || true
            echo '$CLUSTER_ADMIN_USER ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/$CLUSTER_ADMIN_USER
            sudo chmod 440 /etc/sudoers.d/$CLUSTER_ADMIN_USER
        "
        log_info "User $CLUSTER_ADMIN_USER created successfully"
    fi

    # Copy SSH public key
    log_info "Copying SSH public key to $NODE_HOST..."
    exec_remote "$i" "$NODE_HOST" "$NODE_SSH_USER" "
        sudo mkdir -p /home/$CLUSTER_ADMIN_USER/.ssh
        sudo chmod 700 /home/$CLUSTER_ADMIN_USER/.ssh
    "

    # Read public key and append to authorized_keys
    PUB_KEY=$(cat "${SSH_KEY_PATH}.pub")
    exec_remote "$i" "$NODE_HOST" "$NODE_SSH_USER" "
        echo '$PUB_KEY' | sudo tee -a /home/$CLUSTER_ADMIN_USER/.ssh/authorized_keys
        sudo chmod 600 /home/$CLUSTER_ADMIN_USER/.ssh/authorized_keys
        sudo chown -R $CLUSTER_ADMIN_USER:$CLUSTER_ADMIN_USER /home/$CLUSTER_ADMIN_USER/.ssh
    "
    log_info "SSH key copied successfully"

    # Ensure SSH server is configured properly
    log_info "Configuring SSH server..."
    exec_remote "$i" "$NODE_HOST" "$NODE_SSH_USER" "
        sudo sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
        sudo sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
        sudo systemctl reload sshd 2>/dev/null || sudo systemctl reload ssh 2>/dev/null || true
    "
    log_info "SSH server configured"

    echo ""
done

# =============================================================================
# STEP 7: Verify SSH Access with New User
# =============================================================================
log_step "STEP 7: Verifying SSH Access with New Cluster Admin User"
echo ""

ALL_CONNECTIONS_OK=true
for i in $(seq 0 $((NUM_NODES - 1))); do
    NODE_HOST="${NODE_HOSTS[$i]}"
    NODE_NAME="${NODE_NAMES[$i]}"

    log_info "Testing connection to $NODE_NAME ($NODE_HOST)..."
    if test_ssh_connection "$NODE_HOST" "$CLUSTER_ADMIN_USER" "$SSH_KEY_PATH"; then
        log_info "✓ Connection to $NODE_NAME successful"
    else
        log_error "✗ Connection to $NODE_NAME failed"
        ALL_CONNECTIONS_OK=false
    fi
done

if [ "$ALL_CONNECTIONS_OK" = false ]; then
    log_error "Some SSH connections failed. Please check the configuration."
    exit 1
fi

log_info "All SSH connections successful!"
echo ""

# =============================================================================
# STEP 8: Tailscale Setup
# =============================================================================
log_step "STEP 8: Tailscale Setup"
echo ""

declare -a TAILSCALE_IPS
declare -a TAILSCALE_HOSTNAMES

for i in $(seq 0 $((NUM_NODES - 1))); do
    NODE_HOST="${NODE_HOSTS[$i]}"
    NODE_NAME="${NODE_NAMES[$i]}"
    NODE_NUM=$((i + 1))

    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Configuring Tailscale on Node $NODE_NUM: $NODE_NAME ($NODE_HOST)"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Check if Tailscale is installed
    log_info "Checking if Tailscale is installed..."
    if ! ssh -i "$SSH_KEY_PATH" "${CLUSTER_ADMIN_USER}@${NODE_HOST}" "command -v tailscale" &>/dev/null; then
        log_warn "Tailscale is not installed on $NODE_NAME"
        log_info "Installing Tailscale..."

        ssh -i "$SSH_KEY_PATH" "${CLUSTER_ADMIN_USER}@${NODE_HOST}" "
            curl -fsSL https://tailscale.com/install.sh | sudo sh
        "
        log_info "Tailscale installed successfully"
    else
        log_info "Tailscale is already installed"
    fi

    # Check if Tailscale is running and connected
    log_info "Checking Tailscale status..."
    if ssh -i "$SSH_KEY_PATH" "${CLUSTER_ADMIN_USER}@${NODE_HOST}" "sudo tailscale status" &>/dev/null; then
        log_info "Tailscale is running and connected"

        # Get Tailscale IP
        TS_IP=$(ssh -i "$SSH_KEY_PATH" "${CLUSTER_ADMIN_USER}@${NODE_HOST}" "sudo tailscale ip -4" 2>/dev/null | tr -d '\n')
        TS_HOSTNAME=$(ssh -i "$SSH_KEY_PATH" "${CLUSTER_ADMIN_USER}@${NODE_HOST}" "sudo tailscale status --json | jq -r '.Self.HostName'" 2>/dev/null | tr -d '\n')

        if [ -n "$TS_IP" ]; then
            log_info "Tailscale IP: $TS_IP"
            log_info "Tailscale hostname: $TS_HOSTNAME"
            TAILSCALE_IPS+=("$TS_IP")
            TAILSCALE_HOSTNAMES+=("$TS_HOSTNAME")
        else
            log_error "Could not retrieve Tailscale IP"
            exit 1
        fi
    else
        log_warn "Tailscale is not connected"
        log_info "Please connect this node to Tailscale:"
        log_info "  1. SSH to the node: ssh -i $SSH_KEY_PATH ${CLUSTER_ADMIN_USER}@${NODE_HOST}"
        log_info "  2. Run: sudo tailscale up"
        log_info "  3. Follow the authentication link"
        log_info ""
        log_info "Press ENTER when Tailscale is connected on $NODE_NAME..."
        read

        # Verify connection
        if ! ssh -i "$SSH_KEY_PATH" "${CLUSTER_ADMIN_USER}@${NODE_HOST}" "sudo tailscale status" &>/dev/null; then
            log_error "Tailscale is still not connected on $NODE_NAME"
            exit 1
        fi

        # Get Tailscale IP
        TS_IP=$(ssh -i "$SSH_KEY_PATH" "${CLUSTER_ADMIN_USER}@${NODE_HOST}" "sudo tailscale ip -4" 2>/dev/null | tr -d '\n')
        TS_HOSTNAME=$(ssh -i "$SSH_KEY_PATH" "${CLUSTER_ADMIN_USER}@${NODE_HOST}" "sudo tailscale status --json | jq -r '.Self.HostName'" 2>/dev/null | tr -d '\n')

        if [ -n "$TS_IP" ]; then
            log_info "Tailscale IP: $TS_IP"
            log_info "Tailscale hostname: $TS_HOSTNAME"
            TAILSCALE_IPS+=("$TS_IP")
            TAILSCALE_HOSTNAMES+=("$TS_HOSTNAME")
        else
            log_error "Could not retrieve Tailscale IP"
            exit 1
        fi
    fi

    echo ""
done

# =============================================================================
# STEP 9: K3s Installation
# =============================================================================
log_step "STEP 9: K3s Installation"
echo ""

if ask_yes_no "Do you want to install K3s now?" "y"; then
    log_info "Starting K3s installation on all nodes..."
    echo ""

    # Build TLS SAN arguments for K3s
    TLS_SAN_ARGS=""

    # Add domain if configured
    if [ -n "$DOMAIN" ]; then
        TLS_SAN_ARGS="--tls-san $DOMAIN"
    fi

    # Add all node hosts/IPs
    for i in $(seq 0 $((NUM_NODES - 1))); do
        NODE_HOST="${NODE_HOSTS[$i]}"
        TLS_SAN_ARGS="$TLS_SAN_ARGS --tls-san $NODE_HOST"
    done

    # Add all Tailscale IPs
    for i in $(seq 0 $((NUM_NODES - 1))); do
        TS_IP="${TAILSCALE_IPS[$i]}"
        if [ -n "$TS_IP" ]; then
            TLS_SAN_ARGS="$TLS_SAN_ARGS --tls-san $TS_IP"
        fi
    done

    # Add all Tailscale hostnames
    for i in $(seq 0 $((NUM_NODES - 1))); do
        TS_HOSTNAME="${TAILSCALE_HOSTNAMES[$i]}"
        if [ -n "$TS_HOSTNAME" ]; then
            TLS_SAN_ARGS="$TLS_SAN_ARGS --tls-san $TS_HOSTNAME"
        fi
    done

    log_info "TLS SAN arguments: $TLS_SAN_ARGS"
    echo ""

    # Find first master node
    FIRST_MASTER_IDX=-1
    for i in $(seq 0 $((NUM_NODES - 1))); do
        if [ "${NODE_ROLES[$i]}" = "master" ]; then
            FIRST_MASTER_IDX=$i
            break
        fi
    done

    if [ $FIRST_MASTER_IDX -lt 0 ]; then
        log_error "No master node found! At least one master node is required."
        exit 1
    fi

    # Install K3s on first master
    NODE_NAME="${NODE_NAMES[$FIRST_MASTER_IDX]}"
    NODE_HOST="${TAILSCALE_IPS[$FIRST_MASTER_IDX]}"
    FIRST_MASTER_TS_IP="${TAILSCALE_IPS[$FIRST_MASTER_IDX]}"

    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Installing K3s on first master: $NODE_NAME"
    log_info "Using Tailscale IP: $FIRST_MASTER_TS_IP"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if [ "$NUM_NODES" -eq 1 ]; then
        # Single node installation
        ssh -i "$SSH_KEY_PATH" "${CLUSTER_ADMIN_USER}@${NODE_HOST}" "
            curl -sfL https://get.k3s.io | sh -s - server \\
                --node-ip=${FIRST_MASTER_TS_IP} \\
                --node-external-ip=${FIRST_MASTER_TS_IP} \\
                --advertise-address=${FIRST_MASTER_TS_IP} \\
                --flannel-iface=tailscale0 \\
                --write-kubeconfig-mode 644 \\
                $TLS_SAN_ARGS
        "
    else
        # Multi-node HA installation
        ssh -i "$SSH_KEY_PATH" "${CLUSTER_ADMIN_USER}@${NODE_HOST}" "
            curl -sfL https://get.k3s.io | sh -s - server \\
                --cluster-init \\
                --node-ip=${FIRST_MASTER_TS_IP} \\
                --node-external-ip=${FIRST_MASTER_TS_IP} \\
                --advertise-address=${FIRST_MASTER_TS_IP} \\
                --flannel-iface=tailscale0 \\
                --write-kubeconfig-mode 644 \\
                $TLS_SAN_ARGS
        "
    fi

    log_info "✓ K3s installed on $NODE_NAME"
    echo ""

    # Wait for K3s to be ready
    log_info "Waiting for K3s to be ready on $NODE_NAME..."
    ssh -i "$SSH_KEY_PATH" "${CLUSTER_ADMIN_USER}@${NODE_HOST}" "
        timeout 120 bash -c 'until sudo k3s kubectl get nodes &>/dev/null; do sleep 2; done'
    "
    log_info "✓ K3s is ready on $NODE_NAME"
    echo ""

    # Get the token for additional nodes
    if [ "$NUM_NODES" -gt 1 ]; then
        log_info "Retrieving K3s token..."
        K3S_TOKEN=$(ssh -i "$SSH_KEY_PATH" "${CLUSTER_ADMIN_USER}@${NODE_HOST}" "sudo cat /var/lib/rancher/k3s/server/node-token" 2>/dev/null | tr -d '\n')

        if [ -z "$K3S_TOKEN" ]; then
            log_error "Failed to retrieve K3s token from $NODE_NAME"
            exit 1
        fi
        log_info "✓ K3s token retrieved"
        echo ""

        # Install K3s on remaining nodes
        for i in $(seq 0 $((NUM_NODES - 1))); do
            if [ $i -ne $FIRST_MASTER_IDX ]; then
                NODE_NAME="${NODE_NAMES[$i]}"
                NODE_ROLE="${NODE_ROLES[$i]}"
                NODE_HOST="${TAILSCALE_IPS[$i]}"
                NODE_TS_IP="${TAILSCALE_IPS[$i]}"
                FIRST_MASTER_IP="${TAILSCALE_IPS[$FIRST_MASTER_IDX]}"

                log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                log_info "Installing K3s on $NODE_NAME (role: $NODE_ROLE)"
                log_info "Using Tailscale IP: $NODE_TS_IP"
                log_info "Connecting to master: $FIRST_MASTER_IP"
                log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

                case "$NODE_ROLE" in
                    master)
                        ssh -i "$SSH_KEY_PATH" "${CLUSTER_ADMIN_USER}@${NODE_HOST}" "
                            curl -sfL https://get.k3s.io | sh -s - server \\
                                --server https://${FIRST_MASTER_IP}:6443 \\
                                --token '$K3S_TOKEN' \\
                                --node-ip=${NODE_TS_IP} \\
                                --node-external-ip=${NODE_TS_IP} \\
                                --advertise-address=${NODE_TS_IP} \\
                                --flannel-iface=tailscale0 \\
                                $TLS_SAN_ARGS
                        "
                        ;;
                    worker)
                        ssh -i "$SSH_KEY_PATH" "${CLUSTER_ADMIN_USER}@${NODE_HOST}" "
                            curl -sfL https://get.k3s.io | sh -s - agent \\
                                --server https://${FIRST_MASTER_IP}:6443 \\
                                --token '$K3S_TOKEN' \\
                                --node-ip=${NODE_TS_IP} \\
                                --node-external-ip=${NODE_TS_IP} \\
                                --flannel-iface=tailscale0
                        "
                        ;;
                    witness)
                        ssh -i "$SSH_KEY_PATH" "${CLUSTER_ADMIN_USER}@${NODE_HOST}" "
                            curl -sfL https://get.k3s.io | sh -s - server \\
                                --server https://${FIRST_MASTER_IP}:6443 \\
                                --token '$K3S_TOKEN' \\
                                --node-ip=${NODE_TS_IP} \\
                                --node-external-ip=${NODE_TS_IP} \\
                                --advertise-address=${NODE_TS_IP} \\
                                --node-taint node-role.kubernetes.io/witness=true:NoSchedule \\
                                --flannel-iface=tailscale0 \\
                                $TLS_SAN_ARGS
                        "
                        ;;
                esac

                log_info "✓ K3s installed on $NODE_NAME"
                echo ""
            fi
        done

        # Wait for all nodes to be ready
        log_info "Waiting for all nodes to join the cluster..."
        sleep 10

        FIRST_MASTER_IP="${TAILSCALE_IPS[$FIRST_MASTER_IDX]}"
        ssh -i "$SSH_KEY_PATH" "${CLUSTER_ADMIN_USER}@${FIRST_MASTER_IP}" "
            timeout 120 bash -c 'until [ \$(sudo k3s kubectl get nodes --no-headers 2>/dev/null | wc -l) -eq $NUM_NODES ]; do sleep 5; done'
        "

        log_info "✓ All nodes joined the cluster"
        echo ""
    fi

    # Get kubeconfig from first master
    log_info "Retrieving kubeconfig..."
    KUBECONFIG_PATH="$HOME/.kube/config-${DOMAIN}"
    mkdir -p "$HOME/.kube"

    FIRST_MASTER_IP="${TAILSCALE_IPS[$FIRST_MASTER_IDX]}"
    ssh -i "$SSH_KEY_PATH" "${CLUSTER_ADMIN_USER}@${FIRST_MASTER_IP}" "sudo cat /etc/rancher/k3s/k3s.yaml" > "$KUBECONFIG_PATH"

    # Replace localhost with the actual server IP
    sed -i.bak "s/127.0.0.1/${FIRST_MASTER_IP}/g" "$KUBECONFIG_PATH"
    rm -f "${KUBECONFIG_PATH}.bak"

    chmod 600 "$KUBECONFIG_PATH"
    log_info "✓ Kubeconfig saved to: $KUBECONFIG_PATH"
    echo ""

    log_info "To use kubectl with this cluster:"
    echo "  export KUBECONFIG=$KUBECONFIG_PATH"
    echo "  kubectl get nodes"
    echo ""

    # Display cluster status
    log_info "Cluster Status:"
    KUBECONFIG="$KUBECONFIG_PATH" kubectl get nodes
    echo ""

    log_info "✓ K3s installation complete!"
    echo ""
else
    log_info "Skipping K3s installation"
    log_info "You can install K3s manually later using the instructions in the summary"
    echo ""
fi

# =============================================================================
# STEP 10: Post-Installation Configuration Scripts
# =============================================================================
log_step "STEP 10: Post-Installation Configuration"
echo ""

if ask_yes_no "Do you want to run post-installation configuration scripts?" "y"; then
    log_info "Post-installation scripts configure additional cluster components:"
    echo ""
    echo "  Available Scripts:"
    echo "    1. MetalLB LoadBalancer (REQUIRED - LoadBalancer services support)"
    echo "    2. Traefik Ingress + DNS (for HTTP/HTTPS routing with internal domains)"
    echo "    4. HAProxy API LoadBalancer (CRITICAL FOR HA - provides VIP for master failover)"
    echo "    5. Longhorn Storage (REQUIRED - distributed persistent storage)"
    echo "    6. cert-manager (for SSL certificate management with Cloudflare)"
    echo "    7. external-dns (for automatic DNS record management with Cloudflare)"
    echo "    8. Traefik & Kubernetes Dashboards (OPTIONAL - web-based cluster management)"
    echo "    9. Prometheus + Grafana Monitoring (OPTIONAL - metrics and visualization)"
    echo ""

    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)/scripts"

    # Get first master node for script execution
    FIRST_MASTER_IP="${TAILSCALE_IPS[$FIRST_MASTER_IDX]}"
    FIRST_MASTER_NAME="${NODE_NAMES[$FIRST_MASTER_IDX]}"

    # Function to execute script on remote master node
    run_script_on_master() {
        local script_name="$1"
        local script_path="$SCRIPT_DIR/$script_name"

        if [ ! -f "$script_path" ]; then
            log_error "Script not found: $script_path"
            return 1
        fi

        log_info "Copying script to master node: $FIRST_MASTER_NAME ($FIRST_MASTER_IP)"

        # Copy script to master node
        scp -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no "$script_path" \
            "${CLUSTER_ADMIN_USER}@${FIRST_MASTER_IP}:/tmp/$script_name" || {
            log_error "Failed to copy script to master node"
            return 1
        }

        log_info "Executing script on master node..."
        echo ""

        # Build environment variable exports
        local env_vars=""
        env_vars+="export DOMAIN='$DOMAIN' "
        env_vars+="export KUBECONFIG='$KUBECONFIG_PATH' "
        env_vars+="export METALLB_SUBNET='$METALLB_SUBNET' "
        env_vars+="export METALLB_IP_RANGE='$METALLB_IP_RANGE' "
        env_vars+="export TRAEFIK_IP='$TRAEFIK_IP' "
        env_vars+="export NUM_NODES='$NUM_NODES' "

        # Export node information
        for i in $(seq 0 $((NUM_NODES - 1))); do
            env_vars+="export NODE_${i}_NAME='${NODE_NAMES[$i]}' "
            env_vars+="export NODE_${i}_IP='${TAILSCALE_IPS[$i]}' "
            env_vars+="export NODE_${i}_ROLE='${NODE_ROLES[$i]}' "
        done

        # Export master node information if available
        if [ -n "$MASTER_NODE_COUNT" ]; then
            env_vars+="export MASTER_NODE_COUNT='$MASTER_NODE_COUNT' "
            for i in $(seq 0 $((MASTER_NODE_COUNT - 1))); do
                local master_name_var="MASTER_${i}_NAME"
                local master_ip_var="MASTER_${i}_IP"
                env_vars+="export MASTER_${i}_NAME='${!master_name_var}' "
                env_vars+="export MASTER_${i}_IP='${!master_ip_var}' "
            done
        fi

        # Export SSL/domain configuration
        if [ "$DOMAIN_TYPE" = "real" ]; then
            env_vars+="export USE_SSL='true' "
            env_vars+="export SSL_ISSUER='$SSL_ISSUER' "
            env_vars+="export CLOUDFLARE_API_TOKEN='$CLOUDFLARE_API_TOKEN' "
            env_vars+="export ACME_EMAIL='$ACME_EMAIL' "
            env_vars+="export CLUSTER_VIP='$CLUSTER_VIP' "
        else
            env_vars+="export USE_SSL='false' "
        fi

        # Execute script on master node with environment variables
        ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no \
            "${CLUSTER_ADMIN_USER}@${FIRST_MASTER_IP}" \
            "$env_vars bash /tmp/$script_name" || {
            log_error "Script execution failed on master node"
            return 1
        }

        log_info "Script completed successfully"
        echo ""

        # Clean up
        ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no \
            "${CLUSTER_ADMIN_USER}@${FIRST_MASTER_IP}" \
            "rm -f /tmp/$script_name" 2>/dev/null || true

        return 0
    }

    # Determine recommended scripts based on domain type
    if [ "$DOMAIN_TYPE" = "real" ]; then
        log_info "Based on your external domain configuration, recommended scripts are:"
        echo "  • Required: 1 (MetalLB), 4 (HAProxy VIP), 5 (Longhorn), 6 (cert-manager), 7 (external-dns)"
        echo "  • Optional: 2 (Traefik Ingress), 8 (Dashboards), 9 (Monitoring)"
        echo ""
        DEFAULT_SCRIPTS="1,4,5,6,7"
    else
        log_info "Based on your internal domain configuration, recommended scripts are:"
        echo "  • Required: 1 (MetalLB), 2 (Traefik Ingress), 4 (HAProxy VIP), 5 (Longhorn)"
        echo "  • Optional: 8 (Dashboards), 9 (Monitoring)"
        echo "  • Not needed: 6 (cert-manager - Cloudflare), 7 (external-dns - Cloudflare)"
        echo ""
        DEFAULT_SCRIPTS="1,2,4,5"
    fi

    read -p "Enter script numbers to run (comma-separated) [default: $DEFAULT_SCRIPTS]: " SCRIPTS_TO_RUN
    SCRIPTS_TO_RUN=${SCRIPTS_TO_RUN:-$DEFAULT_SCRIPTS}

    # Convert comma-separated list to array
    IFS=',' read -ra SCRIPT_ARRAY <<< "$SCRIPTS_TO_RUN"

    # Set up environment variables for scripts
    export DOMAIN="$DOMAIN"
    export KUBECONFIG="$KUBECONFIG_PATH"

    # Export Tailscale network configuration for MetalLB
    export METALLB_SUBNET="100.106.200.0/24"
    export METALLB_IP_RANGE="100.106.200.10-100.106.200.50"
    export TRAEFIK_IP="100.106.200.20"

    # Export node information for all scripts
    export NUM_NODES="$NUM_NODES"
    for i in $(seq 0 $((NUM_NODES - 1))); do
        export "NODE_${i}_NAME=${NODE_NAMES[$i]}"
        export "NODE_${i}_IP=${TAILSCALE_IPS[$i]}"
        export "NODE_${i}_ROLE=${NODE_ROLES[$i]}"
    done

    if [ "$DOMAIN_TYPE" = "real" ]; then
        export USE_SSL="true"
        export SSL_ISSUER="letsencrypt-staging"
        export CLOUDFLARE_API_TOKEN="$CLOUDFLARE_API_KEY"
        export ACME_EMAIL="${ACME_EMAIL:-admin@${DOMAIN}}"

        log_info "SSL Configuration:"
        echo "  Current SSL issuer: letsencrypt-staging (for testing)"
        echo ""
        log_warn "IMPORTANT: You are using Let's Encrypt STAGING issuer"
        log_warn "Staging certificates are for testing only and will show browser warnings"
        log_warn "After testing, you should switch to production issuer"
        echo ""

        if ask_yes_no "Do you want to use Let's Encrypt PRODUCTION issuer instead?" "n"; then
            export SSL_ISSUER="letsencrypt-prod"
            log_info "Using production issuer: letsencrypt-prod"
            log_warn "Be careful with rate limits: 50 certificates per domain per week"
        else
            log_info "Using staging issuer for testing"
        fi
        echo ""

        # Auto-detect cluster VIP for external-dns
        FIRST_MASTER_IP="${TAILSCALE_IPS[$FIRST_MASTER_IDX]}"
        export CLUSTER_VIP="$FIRST_MASTER_IP"
        log_info "Cluster VIP (for DNS records): $CLUSTER_VIP"
        echo ""
    else
        export USE_SSL="false"
        log_info "SSL is disabled for internal domain"
        echo ""
    fi

    # Run selected scripts
    for script_num in "${SCRIPT_ARRAY[@]}"; do
        # Trim whitespace
        script_num=$(echo "$script_num" | tr -d ' ')

        case "$script_num" in
            1)
                log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                log_info "Running Script 1: MetalLB LoadBalancer"
                log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo ""
                log_info "MetalLB provides LoadBalancer service support for bare-metal clusters"
                log_info "This is required for services that need external IPs"
                echo ""

                if [ -f "$SCRIPT_DIR/1.setup-metallb-demo.sh" ]; then
                    bash "$SCRIPT_DIR/1.setup-metallb-demo.sh"
                    echo ""
                else
                    log_error "Script not found: $SCRIPT_DIR/1.setup-metallb-demo.sh"
                fi
                ;;
            2)
                log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                log_info "Running Script 2: Traefik Ingress + DNS"
                log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo ""
                log_info "Configures Traefik ingress controller and internal DNS resolution"
                log_info "This enables HTTP/HTTPS routing using .local domain names"
                echo ""

                if [ -f "$SCRIPT_DIR/2.setup-ingress-dns.sh" ]; then
                    bash "$SCRIPT_DIR/2.setup-ingress-dns.sh"
                    echo ""
                else
                    log_error "Script not found: $SCRIPT_DIR/2.setup-ingress-dns.sh"
                fi
                ;;
            4)
                log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                log_info "Running Script 4: HAProxy API LoadBalancer (CRITICAL FOR HA)"
                log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo ""
                log_info "Sets up HAProxy load balancer for K3s API server High Availability"
                log_info "This provides a Virtual IP (VIP) for accessing master nodes"
                log_info "Critical for cluster HA - allows failover between master nodes"
                echo ""

                # Export master node IPs for HAProxy configuration
                export MASTER_NODE_COUNT=0
                for i in $(seq 0 $((NUM_NODES - 1))); do
                    if [ "${NODE_ROLES[$i]}" = "master" ]; then
                        export "MASTER_${MASTER_NODE_COUNT}_NAME=${NODE_NAMES[$i]}"
                        export "MASTER_${MASTER_NODE_COUNT}_IP=${TAILSCALE_IPS[$i]}"
                        MASTER_NODE_COUNT=$((MASTER_NODE_COUNT + 1))
                    fi
                done
                export MASTER_NODE_COUNT

                log_info "Master nodes for load balancing:"
                for i in $(seq 0 $((MASTER_NODE_COUNT - 1))); do
                    MASTER_NAME_VAR="MASTER_${i}_NAME"
                    MASTER_IP_VAR="MASTER_${i}_IP"
                    echo "  - ${!MASTER_NAME_VAR}: ${!MASTER_IP_VAR}"
                done
                echo ""

                if [ -f "$SCRIPT_DIR/4.setup-api-loadbalancer.sh" ]; then
                    bash "$SCRIPT_DIR/4.setup-api-loadbalancer.sh"
                    echo ""
                else
                    log_error "Script not found: $SCRIPT_DIR/4.setup-api-loadbalancer.sh"
                fi
                ;;
            5)
                log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                log_info "Running Script 5: Longhorn Storage"
                log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo ""
                log_info "Installs Longhorn distributed storage system"
                log_info "This provides persistent storage for your cluster workloads"
                echo ""

                if [ -f "$SCRIPT_DIR/5.deploy-longhorn.sh" ]; then
                    bash "$SCRIPT_DIR/5.deploy-longhorn.sh"
                    echo ""
                else
                    log_error "Script not found: $SCRIPT_DIR/5.deploy-longhorn.sh"
                fi
                ;;
            6)
                log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                log_info "Running Script 6: cert-manager"
                log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo ""
                log_info "Installs cert-manager with Cloudflare DNS challenge"
                log_info "This automates SSL certificate management with Let's Encrypt"
                echo ""

                if [ -f "$SCRIPT_DIR/6.setup-cert-manager.sh" ]; then
                    bash "$SCRIPT_DIR/6.setup-cert-manager.sh"
                    echo ""
                else
                    log_error "Script not found: $SCRIPT_DIR/6.setup-cert-manager.sh"
                fi
                ;;
            7)
                log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                log_info "Running Script 7: external-dns"
                log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo ""
                log_info "Installs external-dns with Cloudflare provider"
                log_info "This automatically manages DNS records for your Ingress resources"
                echo ""

                if [ -f "$SCRIPT_DIR/7.setup-external-dns.sh" ]; then
                    bash "$SCRIPT_DIR/7.setup-external-dns.sh"
                    echo ""
                else
                    log_error "Script not found: $SCRIPT_DIR/7.setup-external-dns.sh"
                fi
                ;;
            8)
                log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                log_info "Running Script 8: Dashboards"
                log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo ""
                log_info "Sets up Traefik and Kubernetes dashboards"
                log_info "This provides web-based management interfaces for your cluster"
                echo ""

                if [ -f "$SCRIPT_DIR/8.setup-dashboards.sh" ]; then
                    bash "$SCRIPT_DIR/8.setup-dashboards.sh"
                    echo ""
                else
                    log_error "Script not found: $SCRIPT_DIR/8.setup-dashboards.sh"
                fi
                ;;
            9)
                log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                log_info "Running Script 9: Monitoring"
                log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                echo ""
                log_info "Installs Prometheus and Grafana monitoring stack"
                log_info "This provides metrics collection and visualization for your cluster"
                echo ""

                if [ -f "$SCRIPT_DIR/9.deploy-monitoring.sh" ]; then
                    bash "$SCRIPT_DIR/9.deploy-monitoring.sh"
                    echo ""
                else
                    log_error "Script not found: $SCRIPT_DIR/9.deploy-monitoring.sh"
                fi
                ;;
            *)
                log_warn "Unknown script number: $script_num (skipping)"
                ;;
        esac
    done

    log_info "✓ Post-installation configuration complete!"
    echo ""
else
    log_info "Skipping post-installation configuration"
    log_info "You can run individual scripts manually later from: $SCRIPT_DIR"
    echo ""
fi

# =============================================================================
# STEP 11: Final Summary
# =============================================================================
log_step "STEP 11: Final Summary"
echo ""

echo -e "${GREEN}╔═══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║                                                           ║${NC}"
echo -e "${GREEN}║              Cluster Setup Complete!                     ║${NC}"
echo -e "${GREEN}║                                                           ║${NC}"
echo -e "${GREEN}╚═══════════════════════════════════════════════════════════╝${NC}"
echo ""

log_info "Domain Configuration:"
echo "  Type: $DOMAIN_TYPE"
echo "  Domain: $DOMAIN"
if [ "$DOMAIN_TYPE" = "real" ]; then
    echo "  Cloudflare API Key: ***configured***"
fi
echo ""

log_info "SSH Configuration:"
echo "  Cluster admin user: $CLUSTER_ADMIN_USER"
echo "  SSH private key: $SSH_KEY_PATH"
echo "  SSH public key: ${SSH_KEY_PATH}.pub"
echo ""

log_info "Cluster Nodes:"
for i in $(seq 0 $((NUM_NODES - 1))); do
    NODE_NUM=$((i + 1))
    NODE_ROLE_DISPLAY="${NODE_ROLES[$i]}"

    echo ""
    echo "  Node $NODE_NUM ($NODE_ROLE_DISPLAY):"
    echo "    Hostname: ${NODE_NAMES[$i]}"
    echo "    Host/IP Address: ${NODE_HOSTS[$i]}"
    echo "    Tailscale IP: ${TAILSCALE_IPS[$i]}"
    echo "    Tailscale FQDN: ${TAILSCALE_HOSTNAMES[$i]}"
    echo "    SSH Command: ssh -i $SSH_KEY_PATH ${CLUSTER_ADMIN_USER}@${TAILSCALE_IPS[$i]}"
done
echo ""

# Build TLS SAN list for K3s
log_info "K3s TLS Configuration:"
TLS_SAN_LIST=""
TLS_SAN_ARGS=""

# Add domain if configured
if [ -n "$DOMAIN" ]; then
    TLS_SAN_LIST="$DOMAIN"
    TLS_SAN_ARGS="--tls-san $DOMAIN"
    echo "  - Domain: $DOMAIN"
fi

# Add all node hosts/IPs
for i in $(seq 0 $((NUM_NODES - 1))); do
    NODE_HOST="${NODE_HOSTS[$i]}"
    if [ -n "$TLS_SAN_LIST" ]; then
        TLS_SAN_LIST="$TLS_SAN_LIST,$NODE_HOST"
        TLS_SAN_ARGS="$TLS_SAN_ARGS --tls-san $NODE_HOST"
    else
        TLS_SAN_LIST="$NODE_HOST"
        TLS_SAN_ARGS="--tls-san $NODE_HOST"
    fi
    echo "  - Node host: $NODE_HOST"
done

# Add all Tailscale IPs
for i in $(seq 0 $((NUM_NODES - 1))); do
    TS_IP="${TAILSCALE_IPS[$i]}"
    if [ -n "$TS_IP" ]; then
        TLS_SAN_LIST="$TLS_SAN_LIST,$TS_IP"
        TLS_SAN_ARGS="$TLS_SAN_ARGS --tls-san $TS_IP"
        echo "  - Tailscale IP: $TS_IP"
    fi
done

# Add all Tailscale hostnames
for i in $(seq 0 $((NUM_NODES - 1))); do
    TS_HOSTNAME="${TAILSCALE_HOSTNAMES[$i]}"
    if [ -n "$TS_HOSTNAME" ]; then
        TLS_SAN_LIST="$TLS_SAN_LIST,$TS_HOSTNAME"
        TLS_SAN_ARGS="$TLS_SAN_ARGS --tls-san $TS_HOSTNAME"
        echo "  - Tailscale FQDN: $TS_HOSTNAME"
    fi
done

echo ""
log_info "Complete TLS SAN arguments for K3s:"
echo "  $TLS_SAN_ARGS"
echo ""

# Save configuration to file
CONFIG_FILE="$HOME/.k3s-cluster-${DOMAIN}.conf"
cat > "$CONFIG_FILE" <<EOF
# K3s HA Cluster Configuration
# Generated: $(date)

# Cluster Configuration
NUM_NODES=$NUM_NODES

# Domain Configuration
DOMAIN_TYPE="$DOMAIN_TYPE"
DOMAIN="$DOMAIN"
$([ "$DOMAIN_TYPE" = "real" ] && echo "CLOUDFLARE_API_KEY=\"$CLOUDFLARE_API_KEY\"")

# SSH Configuration
CLUSTER_ADMIN_USER="$CLUSTER_ADMIN_USER"
SSH_KEY_PATH="$SSH_KEY_PATH"

# K3s Configuration
$([ -n "$KUBECONFIG_PATH" ] && echo "KUBECONFIG_PATH=\"$KUBECONFIG_PATH\"")
TLS_SAN_ARGS="$TLS_SAN_ARGS"

# Node Configuration
$(for i in $(seq 0 $((NUM_NODES - 1))); do
    echo "NODE${i}_NAME=\"${NODE_NAMES[$i]}\""
    echo "NODE${i}_HOST=\"${NODE_HOSTS[$i]}\""
    echo "NODE${i}_ROLE=\"${NODE_ROLES[$i]}\""
    echo "NODE${i}_TAILSCALE_IP=\"${TAILSCALE_IPS[$i]}\""
    echo "NODE${i}_TAILSCALE_HOSTNAME=\"${TAILSCALE_HOSTNAMES[$i]}\""
    echo ""
done)
EOF

log_info "Configuration saved to: $CONFIG_FILE"
echo ""

if [ -n "$KUBECONFIG_PATH" ]; then
    log_info "Kubectl Access:"
    echo "  export KUBECONFIG=$KUBECONFIG_PATH"
    echo "  kubectl get nodes"
    echo "  kubectl get pods -A"
    echo ""
else
    log_info "Next steps to install K3s:"
    echo ""
    echo "  1. You can now access all nodes using the cluster admin user"
    echo ""

    if [ "$NUM_NODES" -eq 1 ]; then
        echo "  2. To install K3s on the single node:"
        echo "     ssh -i $SSH_KEY_PATH ${CLUSTER_ADMIN_USER}@${TAILSCALE_IPS[0]}"
        echo "     curl -sfL https://get.k3s.io | sh -s - server \\"
        echo "       $TLS_SAN_ARGS"
        echo ""
    else
        # Find first master node
        FIRST_MASTER_IDX=-1
        for i in $(seq 0 $((NUM_NODES - 1))); do
            if [ "${NODE_ROLES[$i]}" = "master" ]; then
                FIRST_MASTER_IDX=$i
                break
            fi
        done

        if [ $FIRST_MASTER_IDX -ge 0 ]; then
            echo "  2. Install K3s on the first control plane (${NODE_NAMES[$FIRST_MASTER_IDX]}):"
            echo "     ssh -i $SSH_KEY_PATH ${CLUSTER_ADMIN_USER}@${TAILSCALE_IPS[$FIRST_MASTER_IDX]}"
            echo "     curl -sfL https://get.k3s.io | sh -s - server \\"
            echo "       --cluster-init \\"
            echo "       $TLS_SAN_ARGS"
            echo ""
            echo "     # Get the token:"
            echo "     sudo cat /var/lib/rancher/k3s/server/node-token"
            echo ""

            STEP_NUM=3
            for i in $(seq 0 $((NUM_NODES - 1))); do
                if [ $i -ne $FIRST_MASTER_IDX ]; then
                    NODE_ROLE="${NODE_ROLES[$i]}"
                    NODE_NAME="${NODE_NAMES[$i]}"
                    TS_IP="${TAILSCALE_IPS[$i]}"

                    echo "  $STEP_NUM. Install K3s on ${NODE_NAME} (${NODE_ROLE}):"
                    echo "     ssh -i $SSH_KEY_PATH ${CLUSTER_ADMIN_USER}@${TS_IP}"

                    case "$NODE_ROLE" in
                        master)
                            echo "     curl -sfL https://get.k3s.io | sh -s - server \\"
                            echo "       --server https://${TAILSCALE_IPS[$FIRST_MASTER_IDX]}:6443 \\"
                            echo "       --token <TOKEN> \\"
                            echo "       $TLS_SAN_ARGS"
                            ;;
                        worker)
                            echo "     curl -sfL https://get.k3s.io | sh -s - agent \\"
                            echo "       --server https://${TAILSCALE_IPS[$FIRST_MASTER_IDX]}:6443 \\"
                            echo "       --token <TOKEN>"
                            ;;
                        witness)
                            echo "     curl -sfL https://get.k3s.io | sh -s - server \\"
                            echo "       --server https://${TAILSCALE_IPS[$FIRST_MASTER_IDX]}:6443 \\"
                            echo "       --token <TOKEN> \\"
                            echo "       --node-taint node-role.kubernetes.io/witness=true:NoSchedule \\"
                            echo "       $TLS_SAN_ARGS"
                            ;;
                    esac
                    echo ""
                    STEP_NUM=$((STEP_NUM + 1))
                fi
            done
        fi

        echo "  $STEP_NUM. Verify cluster status (from any control plane node):"
        echo "     kubectl get nodes"
        echo ""
    fi

    log_info "IMPORTANT: Use the TLS SAN arguments shown above when installing K3s!"
    log_info "This ensures the K3s API server certificate includes all necessary names/IPs."
    echo ""
fi

log_info "Cluster setup complete! 🎉"
