# K3s High-Availability Cluster Setup

Automated installation scripts for deploying a production-ready K3s HA cluster with:

- **3-node etcd quorum** (2 master nodes + 1 cloud witness)
- **Patroni PostgreSQL** with synchronous replication (zero data loss)
- **Longhorn** distributed block storage
- **MetalLB** LoadBalancer for bare-metal
- **Tailscale** mesh VPN for secure networking
- **Prometheus + Grafana** monitoring stack
- **Vaultwarden** password manager (optional demo app)

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    K3s Control Plane (HA)                       │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐    │
│  │ Master 1    │  │ Master 2    │  │ Cloud Witness       │    │
│  │ etcd+work   │  │ etcd+work   │  │ etcd only           │    │
│  └─────────────┘  └─────────────┘  └─────────────────────┘    │
│         ↓               ↓                    ↓                  │
│  ┌──────────────────────────────────────────────────────┐      │
│  │          etcd Cluster (Quorum 2/3)                  │      │
│  └──────────────────────────────────────────────────────┘      │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│                   Application Layer (K8s)                       │
│  • Patroni PostgreSQL (sync replication)                       │
│  • Vaultwarden / other apps                                     │
│  • Longhorn distributed storage                                 │
└─────────────────────────────────────────────────────────────────┘
```

## Prerequisites

### All Nodes

1. **Tailscale installed and connected**
   ```bash
   # Debian/Ubuntu
   curl -fsSL https://tailscale.com/install.sh | sh

   # Arch Linux
   pacman -S tailscale

   # Start and connect
   sudo systemctl enable --now tailscaled
   sudo tailscale up
   ```

2. **SSH access** with either:
   - Key-based authentication (recommended)
   - Password authentication (requires `sshpass` on control machine)

3. **Root access** or sudo privileges

### Control Machine (where you run the installer)

- **Tailscale** installed and connected
- **kubectl** (optional, for management)
- **sshpass** (if using password authentication)
  ```bash
  # Debian/Ubuntu
  apt-get install sshpass

  # Arch Linux
  pacman -S sshpass

  # macOS
  brew install hudochenkov/sshpass/sshpass
  ```

## Quick Start

### 1. Clone or download this repository

```bash
git clone <repository-url>
cd k3s-ha-cluster
```

### 2. Make scripts executable

```bash
chmod +x install-cluster.sh
chmod +x scripts/*.sh
chmod +x master/install-master.sh
chmod +x witness/install-witness.sh
```

### 3. Install First Master Node

```bash
./install-cluster.sh
```

The interactive installer will:
1. Show all Tailscale devices in your network
2. Ask which device to install on
3. Ask if it's a master or witness node
4. Request SSH credentials
5. Perform the installation

**For the first master:**
- Select node type: **Master node**
- Select master type: **First master (initialize cluster)**
- Save the K3s token displayed at the end!

### 4. Install Second Master Node

Run the installer again:
```bash
./install-cluster.sh
```

**For the second master:**
- Select node type: **Master node**
- Select master type: **Additional master (join existing cluster)**
- Provide the K3s token from step 3
- Provide the first master's Tailscale IP

### 5. Install Witness Node

Run the installer one more time:
```bash
./install-cluster.sh
```

**For the witness:**
- Select node type: **Witness node**
- Provide the K3s token from step 3
- Provide the first master's Tailscale IP

### 6. Verify Cluster

From any master node or your control machine (with kubeconfig):

```bash
kubectl get nodes

# Expected output:
# NAME      STATUS   ROLES                  AGE
# master1   Ready    control-plane,master   10m
# master2   Ready    control-plane,master   5m
# witness   Ready    control-plane,master   1m
```

### 7. Deploy Cluster Services

On your control machine or first master:

```bash
# 1. Install Longhorn storage (required first)
./scripts/deploy-longhorn.sh

# 2. Install MetalLB LoadBalancer
./scripts/deploy-metallb.sh

# 3. Install PostgreSQL with Patroni
./scripts/deploy-database.sh

# 4. Install Vaultwarden (optional demo app)
./scripts/deploy-vaultwarden.sh

# 5. Install monitoring stack (optional but recommended)
./scripts/deploy-monitoring.sh
```

## Directory Structure

```
k3s-ha-cluster/
├── install-cluster.sh              # Interactive installer
├── README.md                        # This file
│
├── master/
│   └── install-master.sh           # Master node installation script
│
├── witness/
│   └── install-witness.sh          # Witness node installation script
│
├── manifests/
│   ├── database/                   # PostgreSQL + Patroni manifests
│   │   ├── 01-namespace.yaml
│   │   ├── 02-etcd.yaml
│   │   ├── 03-patroni-secrets.yaml
│   │   ├── 04-patroni-rbac.yaml
│   │   ├── 05-patroni-services.yaml
│   │   └── 06-patroni-statefulset.yaml
│   │
│   ├── storage/                    # Storage configurations
│   │   └── longhorn-storageclass.yaml
│   │
│   ├── network/                    # Network configurations
│   │   └── metallb-ippool.yaml
│   │
│   ├── apps/                       # Application deployments
│   │   ├── 01-namespace.yaml
│   │   ├── 02-vaultwarden-secret.yaml
│   │   └── 03-vaultwarden-deployment.yaml
│   │
│   └── monitoring/                 # Monitoring stack
│       └── prometheus-values.yaml
│
└── scripts/                        # Deployment helper scripts
    ├── deploy-longhorn.sh
    ├── deploy-metallb.sh
    ├── deploy-database.sh
    ├── deploy-vaultwarden.sh
    └── deploy-monitoring.sh
```

## Configuration

### Storage Directories

Default storage directory: `/mnt/k3s-storage`

For master nodes with external storage (Raspberry Pi with SSD):

```bash
# Format and mount (before running installer)
sudo mkfs.ext4 /dev/sda
sudo mkdir -p /mnt/k3s-storage
echo "/dev/sda /mnt/k3s-storage ext4 defaults,nofail 0 2" | sudo tee -a /etc/fstab
sudo mount -a
```

### Passwords

**IMPORTANT:** Change default passwords before production use!

Edit these files:
- `manifests/database/03-patroni-secrets.yaml` - PostgreSQL passwords
- `manifests/apps/02-vaultwarden-secret.yaml` - Vaultwarden database password
- `manifests/monitoring/prometheus-values.yaml` - Grafana admin password

### MetalLB IP Range

Default IP range: `100.100.100.20-100.100.100.30`

To customize:
- Edit `manifests/network/metallb-ippool.yaml` before deploying
- Or use the interactive option in `./scripts/deploy-metallb.sh`

## Management

### Accessing Services

**Grafana (Monitoring):**
```bash
kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80
# Open: http://localhost:3000
# Login: admin / admin
```

**Longhorn UI (Storage):**
```bash
kubectl port-forward -n longhorn-system svc/longhorn-frontend 8080:80
# Open: http://localhost:8080
```

**PostgreSQL:**
```bash
kubectl exec -it -n database patroni-0 -- psql -U postgres
```

### Cluster Status

```bash
# Nodes
kubectl get nodes

# All pods
kubectl get pods -A

# Patroni cluster status
kubectl exec -n database patroni-0 -- patronictl list

# etcd health
kubectl exec -n database etcd-0 -- etcdctl endpoint health --cluster
```

### Logs

```bash
# Pod logs
kubectl logs -n <namespace> <pod-name>

# Follow logs
kubectl logs -n <namespace> <pod-name> -f

# K3s service logs (on node)
sudo journalctl -u k3s -f
```

## Troubleshooting

### Node Not Ready

```bash
# Check node status
kubectl describe node <node-name>

# On the node, check K3s logs
sudo journalctl -u k3s -f

# Restart K3s
sudo systemctl restart k3s
```

### Pod CrashLoopBackOff

```bash
# Describe pod
kubectl describe pod <pod-name> -n <namespace>

# Check logs
kubectl logs <pod-name> -n <namespace>

# Previous crash logs
kubectl logs <pod-name> -n <namespace> --previous
```

### PostgreSQL Not Starting

```bash
# Check etcd health first
kubectl exec -n database etcd-0 -- etcdctl endpoint health --cluster

# Check Patroni logs
kubectl logs -n database patroni-0

# Restart Patroni pod
kubectl delete pod -n database patroni-0
```

### Storage Issues

```bash
# Check Longhorn status
kubectl get pods -n longhorn-system

# Access Longhorn UI to view storage health
kubectl port-forward -n longhorn-system svc/longhorn-frontend 8080:80
```

## Testing Failover

### PostgreSQL Failover

```bash
# Delete master pod to simulate failure
kubectl delete pod -n database patroni-0

# Watch cluster recover (10-20 seconds)
watch kubectl exec -n database patroni-1 -- patronictl list

# Verify applications still work
curl http://<vaultwarden-ip>:8080/alive
```

### Node Failover

```bash
# Drain a master node
kubectl drain master1 --ignore-daemonsets --delete-emptydir-data

# Watch pods migrate to other node
kubectl get pods -A -o wide

# Uncordon when done
kubectl uncordon master1
```

## Backup and Restore

### PostgreSQL Backup

Manual backup:
```bash
kubectl exec -n database patroni-0 -- pg_dumpall -U postgres | gzip > backup-$(date +%Y%m%d).sql.gz
```

Restore:
```bash
gunzip < backup-YYYYMMDD.sql.gz | kubectl exec -i -n database patroni-0 -- psql -U postgres
```

## Maintenance

### Update K3s

On each node (one at a time):
```bash
curl -sfL https://get.k3s.io | sh -
```

### Scale Applications

```bash
# Scale Vaultwarden
kubectl scale deployment vaultwarden -n apps --replicas=3

# Scale PostgreSQL replicas
kubectl scale statefulset patroni -n database --replicas=3
```

## Recommended Next Steps

1. **Change all default passwords**
2. **Configure automated backups**
3. **Set up Prometheus alerts**
4. **Configure TLS/SSL certificates** (cert-manager)
5. **Configure Tailscale DNS** for internal hostnames
6. **Test failover scenarios**

## Support

For issues or questions:
- K3s: https://docs.k3s.io
- Patroni: https://patroni.readthedocs.io
- Longhorn: https://longhorn.io/docs
- Tailscale: https://tailscale.com/kb

## License

MIT License - see repository for details
