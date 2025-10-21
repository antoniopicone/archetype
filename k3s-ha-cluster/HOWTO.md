# Kubernetes HA Cluster con Patroni PostgreSQL

Architettura High-Availability per ecosistema distribuito con ridondanza completa e zero data loss.

## 📋 Indice

1. [Architettura](#architettura)
2. [Componenti Software](#componenti-software)
3. [Requisiti Hardware](#requisiti-hardware)
4. [Prerequisiti](#prerequisiti)
5. [Installazione](#installazione)
6. [Configurazione Cluster](#configurazione-cluster)
7. [Deploy Applicazioni](#deploy-applicazioni)
8. [Testing e Verifica](#testing-e-verifica)
9. [Manutenzione](#manutenzione)
10. [Troubleshooting](#troubleshooting)

---

## 🏗️ Architettura

```
┌─────────────────────────────────────────────────────────────────┐
│                         Client Layer                            │
│  Browser/Mobile → Tailscale VPN → vaultwarden.internal         │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│                    K3s Control Plane (HA)                       │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐    │
│  │ Raspberry 1 │  │ Raspberry 2 │  │ Cloud Witness       │    │
│  │ (Master)    │  │ (Master)    │  │ (etcd only)         │    │
│  │ etcd + work │  │ etcd + work │  │ NoSchedule taint    │    │
│  └─────────────┘  └─────────────┘  └─────────────────────┘    │
│         ↓               ↓                    ↓                  │
│  ┌──────────────────────────────────────────────────────┐      │
│  │          etcd Cluster (Quorum 2/3)                  │      │
│  │  Leader Election • Service Discovery • Config Store  │      │
│  └──────────────────────────────────────────────────────┘      │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│                   Application Layer (K8s)                       │
│  ┌────────────────────────────────────────────────────────┐    │
│  │ Patroni PostgreSQL (Synchronous Replication)          │    │
│  │  Master (Raspi1) ←sync→ Replica (Raspi2/PC)          │    │
│  │  ✓ Zero Data Loss  ✓ Auto Failover  ✓ PITR Backup    │    │
│  └────────────────────────────────────────────────────────┘    │
│  ┌────────────────────────────────────────────────────────┐    │
│  │ Vaultwarden Pods (N replicas)                         │    │
│  │  Password Manager • Multi-pod • Auto-scaling          │    │
│  └────────────────────────────────────────────────────────┘    │
│  ┌────────────────────────────────────────────────────────┐    │
│  │ Nextcloud / Altri Servizi (future)                    │    │
│  └────────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│                    Storage Layer (Longhorn)                     │
│  Distributed Block Storage • 2x Replication • Auto-healing     │
│  ┌──────────────┐                    ┌──────────────┐          │
│  │ Raspi1 SSD   │ ←── sync data ──→  │ Raspi2 SSD   │          │
│  │ 50GB         │                    │ 50GB         │          │
│  └──────────────┘                    └──────────────┘          │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│                    Monitoring & Observability                   │
│  Prometheus • Grafana • AlertManager • Loki                    │
└─────────────────────────────────────────────────────────────────┘
```

### Flusso di Failover Automatico

```
Scenario Normale:
┌───────────┐                ┌───────────┐                ┌──────────┐
│ Raspi1    │                │ Raspi2    │                │ Witness  │
│ Master    │ ←──sync rep──→ │ Replica   │                │ etcd     │
│ etcd ✓    │                │ etcd ✓    │                │ etcd ✓   │
│ PG Master │                │ PG Sync   │                │          │
└───────────┘                └───────────┘                └──────────┘

Failover (Raspi1 cade):
┌───────────┐                ┌───────────┐                ┌──────────┐
│ Raspi1    │                │ Raspi2    │                │ Witness  │
│ DOWN ✗    │                │ NEW MASTER│                │ etcd ✓   │
│           │                │ etcd ✓    │ ←─quorum 2/3─→ │          │
│           │                │ PG Master │                │          │
└───────────┘                └───────────┘                └──────────┘
    ↓                             ↑
    └──── 15s failover ───────────┘
```

---

## 🔧 Componenti Software

| Componente | Versione | Ruolo | Nodi |
|------------|----------|-------|------|
| **K3s** | v1.28+ | Kubernetes lightweight | Raspi1, Raspi2, Witness |
| **etcd** | 3.5+ (embedded) | Consensus & Service Discovery | Tutti i master |
| **Patroni** | 3.2+ | PostgreSQL HA Orchestrator | Raspi1, Raspi2 |
| **PostgreSQL** | 15+ | Database principale | Raspi1, Raspi2 |
| **Longhorn** | 1.6+ | Distributed Block Storage | Raspi1, Raspi2 |
| **Tailscale** | Latest | Mesh VPN (100.x.x.x/10) | Tutti i nodi |
| **Vaultwarden** | Latest | Password Manager (Bitwarden-compatible) | Multi-pod |
| **MetalLB** | 0.14+ | LoadBalancer per bare-metal | Cluster-wide |
| **CoreDNS** | Embedded | DNS interno cluster | K3s built-in |
| **Prometheus Stack** | Latest | Monitoring & Alerting | Cluster-wide |
| **pgBackRest** | 2.48+ | PostgreSQL Backup & PITR | Raspi1, Raspi2 |

---

## 💻 Requisiti Hardware

### Nodo 1: Raspberry Pi (Debian/Raspbian)
- **Modello**: Raspberry Pi 4 (4GB RAM minimo, 8GB consigliato)
- **Storage**: SSD esterno USB 3.0 da 64GB+ (NO microSD per storage dati)
- **Rete**: Ethernet Gigabit (consigliato) o WiFi stabile
- **OS**: Raspberry Pi OS (64-bit) o Debian 11/12

### Nodo 2: Raspberry Pi o PC (Arch Linux)
- **Raspberry Pi 4**: Stesse specifiche del Nodo 1
- **PC x86_64**:
  - CPU: 2+ core
  - RAM: 4GB+ (8GB consigliato)
  - Storage: 50GB+ SSD
  - OS: Arch Linux (kernel 6.0+)

### Nodo 3: Cloud Witness
- **Provider**: Oracle Cloud (free tier), Hetzner, Vultr
- **Specs**: 1 vCPU, 512MB-1GB RAM, 10GB storage
- **OS**: Ubuntu 22.04 LTS o Debian 12
- **Costo**: 0-5€/mese

### Opzionale: macOS Client (Apple Silicon)
- **Uso**: Gestione cluster (kubectl), development
- **Modello**: M1/M2/M3 Mac (macOS 13+)
- **Non esegue workload**, solo client tools

---

## 📦 Prerequisiti

### Comuni a tutti i nodi Linux

```bash
# Update sistema
sudo apt-get update && sudo apt-get upgrade -y  # Debian/Ubuntu
sudo pacman -Syu  # Arch Linux

# Disabilita swap (richiesto da Kubernetes)
sudo swapoff -a
sudo sed -i '/ swap / s/^/#/' /etc/fstab

# Abilita moduli kernel
cat <<EOF | sudo tee /etc/modules-load.d/k3s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

# Sysctl settings
cat <<EOF | sudo tee /etc/sysctl.d/k3s.conf
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF

sudo sysctl --system

# Tools base
sudo apt-get install -y curl wget git vim htop # Debian
sudo pacman -S curl wget git vim htop           # Arch
```

---

## 🚀 Installazione

### 1. Installazione Tailscale (TUTTI i nodi)

#### Raspberry Pi / PC Linux (Debian-based)

```bash
# Aggiungi repository Tailscale
curl -fsSL https://pkgs.tailscale.com/stable/debian/bullseye.noarmor.gpg | sudo tee /usr/share/keyrings/tailscale-archive-keyring.gpg >/dev/null
curl -fsSL https://pkgs.tailscale.com/stable/debian/bullseye.tailscale-keyring.list | sudo tee /etc/apt/sources.list.d/tailscale.list

# Installa
sudo apt-get update
sudo apt-get install -y tailscale

# Avvia e connetti
sudo tailscale up

# Abilita autostart
sudo systemctl enable --now tailscaled
```

#### Arch Linux

```bash
# Installa da repository ufficiale
sudo pacman -S tailscale

# Avvia servizio
sudo systemctl enable --now tailscaled

# Connetti
sudo tailscale up
```

#### macOS (Apple Silicon)

```bash
# Download da App Store o:
brew install --cask tailscale

# Oppure download manuale
# https://tailscale.com/download/mac

# Avvia app e fai login
```

#### Cloud Witness (Ubuntu/Debian)

```bash
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
```

**Verifica su tutti i nodi:**
```bash
tailscale ip -4
# Esempio output: 100.100.100.1

tailscale status
# Dovresti vedere tutti gli altri nodi
```

**Salva gli IP Tailscale** (useremo questi ovunque):
```bash
# Esempio:
RASPI1_IP=100.100.100.1
RASPI2_IP=100.100.100.2
WITNESS_IP=100.100.100.3
PC_IP=100.100.100.4  # Se usi PC invece di secondo Raspi
```

---

### 2. Preparazione Storage (Solo Raspi1 e Raspi2/PC)

#### Raspberry Pi con SSD Esterno

```bash
# Identifica SSD
lsblk
# Esempio: /dev/sda

# Formatta (ATTENZIONE: cancella tutti i dati!)
sudo mkfs.ext4 /dev/sda

# Monta permanentemente
sudo mkdir -p /mnt/k3s-storage
echo "/dev/sda /mnt/k3s-storage ext4 defaults,nofail 0 2" | sudo tee -a /etc/fstab
sudo mount -a

# Verifica
df -h | grep k3s-storage
```

#### Arch Linux (PC con SSD interno)

```bash
# Identifica partizione
lsblk

# Crea directory
sudo mkdir -p /mnt/k3s-storage

# Se hai partizione dedicata
sudo mkfs.ext4 /dev/sdXN
echo "/dev/sdXN /mnt/k3s-storage ext4 defaults 0 2" | sudo tee -a /etc/fstab
sudo mount -a

# Oppure usa directory esistente
sudo mkdir -p /opt/k3s-storage
sudo ln -s /opt/k3s-storage /mnt/k3s-storage
```

---

### 3. Installazione K3s

#### A. Raspberry Pi 1 (Primo Master)

```bash
# Imposta variabili
export RASPI1_IP=$(tailscale ip -4)

# Installa K3s server con cluster-init
curl -sfL https://get.k3s.io | sh -s - server \
  --cluster-init \
  --node-ip=$RASPI1_IP \
  --advertise-address=$RASPI1_IP \
  --bind-address=$RASPI1_IP \
  --flannel-iface=tailscale0 \
  --write-kubeconfig-mode=644 \
  --disable=traefik \
  --disable=servicelb \
  --data-dir=/mnt/k3s-storage/k3s

# Attendi avvio (30-60 secondi)
sudo systemctl status k3s

# Verifica nodo
sudo k3s kubectl get nodes

# Salva token per altri nodi
sudo cat /var/lib/rancher/k3s/server/node-token > ~/k3s-token.txt
K3S_TOKEN=$(cat ~/k3s-token.txt)
echo "Token: $K3S_TOKEN"
```

**Copia il token**, servirà per gli altri nodi!

#### B. Raspberry Pi 2 / PC (Secondo Master)

**Debian/Raspbian (Raspberry Pi 2):**
```bash
# Imposta variabili (usa il token dal Raspi1!)
export RASPI1_IP=100.106.192.46  # IP Tailscale del Raspi1
export K3S_TOKEN="K100b5e8627fe22a3ca2e0a85c56379af11108322c44446b717e7929736e783811c::server:1d9e59af64f88d488fa42bc0ae905c0e"  # Token dal Raspi1
export RASPI2_IP=$(tailscale ip -4)

# Installa K3s come server aggiuntivo
curl -sfL https://get.k3s.io | K3S_TOKEN=$K3S_TOKEN sh -s - server \
  --server https://$RASPI1_IP:6443 \
  --node-ip=$RASPI2_IP \
  --advertise-address=$RASPI2_IP \
  --bind-address=$RASPI2_IP \
  --flannel-iface=tailscale0 \
  --write-kubeconfig-mode=644 \
  --disable=traefik \
  --disable=servicelb \
  --data-dir=/mnt/commedia_italiana/k3s-storage/k3s

# Verifica
sudo k3s kubectl get nodes
```

**Arch Linux (PC):**
```bash
# Stessi comandi ma con export aggiornati
export RASPI1_IP=100.100.100.1
export K3S_TOKEN="..."
export PC_IP=$(tailscale ip -4)

curl -sfL https://get.k3s.io | K3S_TOKEN=$K3S_TOKEN sh -s - server \
  --server https://$RASPI1_IP:6443 \
  --node-ip=$PC_IP \
  --advertise-address=$PC_IP \
  --bind-address=$PC_IP \
  --flannel-iface=tailscale0 \
  --write-kubeconfig-mode=644 \
  --disable=traefik \
  --disable=servicelb \
  --data-dir=/opt/k3s-storage/k3s

# Verifica
sudo k3s kubectl get nodes
# Output atteso: 2 nodi Ready
```

#### C. Cloud Witness (etcd-only)

```bash
# Su VM cloud
export RASPI1_IP=100.100.100.1  # IP Tailscale Raspi1
export K3S_TOKEN="..."           # Token dal Raspi1
export WITNESS_IP=$(tailscale ip -4)

# Installa come server MA con taint NoSchedule (no workload)
curl -sfL https://get.k3s.io | K3S_TOKEN=$K3S_TOKEN sh -s - server \
  --server https://$RASPI1_IP:6443 \
  --node-ip=$WITNESS_IP \
  --advertise-address=$WITNESS_IP \
  --bind-address=$WITNESS_IP \
  --flannel-iface=tailscale0 \
  --write-kubeconfig-mode=644 \
  --disable=traefik \
  --disable=servicelb \
  --node-taint node-role.kubernetes.io/witness=true:NoSchedule

# Verifica cluster completo
sudo k3s kubectl get nodes

# Output atteso:
# NAME      STATUS   ROLES                  AGE
# raspi1    Ready    control-plane,master   10m
# raspi2    Ready    control-plane,master   5m
# witness   Ready    control-plane,master   1m
```

#### D. macOS (Client di gestione - OPZIONALE)

```bash
# Installa kubectl
brew install kubectl

# Copia kubeconfig dal Raspi1
mkdir -p ~/.kube
scp pi@$RASPI1_IP:/etc/rancher/k3s/k3s.yaml ~/.kube/config

# Modifica server URL
sed -i '' "s/127.0.0.1/$RASPI1_IP/g" ~/.kube/config

# Test
kubectl get nodes
kubectl cluster-info

# Installa Helm
brew install helm

# Installa k9s (UI terminale - opzionale ma utile)
brew install derailed/k9s/k9s
```

**Verifica etcd quorum (da qualsiasi nodo o macOS):**
```bash
sudo k3s kubectl get nodes -o wide

# Dovresti vedere 3 pod etcd (uno per nodo)
```

---

### 4. Installazione Longhorn (Storage Distribuito)

**Prerequisiti sui nodi worker (Raspi1, Raspi2/PC):**

```bash
# Debian/Ubuntu
sudo apt-get install -y open-iscsi nfs-common

# Arch Linux
sudo pacman -S open-iscsi nfs-utils

# Abilita servizio iSCSI
sudo systemctl enable --now iscsid
```

**Deploy Longhorn:**

```bash

# Prerequisiti sui nodi worker (raspi1, raspi2 - NON witness)
# Su raspi1:
sudo apt-get install -y open-iscsi nfs-common
sudo systemctl enable --now iscsid

# Su raspi2:
sudo apt-get install -y open-iscsi nfs-common
sudo systemctl enable --now iscsid

# Da qualsiasi nodo con kubectl o da macOS
kubectl apply -f https://raw.githubusercontent.com/longhorn/longhorn/v1.6.0/deploy/longhorn.yaml

# Attendi completamento (3-5 minuti)
kubectl get pods -n longhorn-system -w
# Premi Ctrl+C quando tutti i pod sono Running

# Crea StorageClass default, SOLO quando tutti i pod sono Running
cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: longhorn-replicated
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: driver.longhorn.io
allowVolumeExpansion: true
parameters:
  numberOfReplicas: "2"
  staleReplicaTimeout: "2880"
  fromBackup: ""
  fsType: "ext4"
EOF

# Verifica
kubectl get storageclass
```

**Accesso UI Longhorn (opzionale):**
```bash
# Da macOS o nodo
kubectl port-forward -n longhorn-system svc/longhorn-frontend 8080:80 --address 0.0.0.0

# Apri browser: http://localhost:8080
```

---

### 5. Installazione etcd esterno (per Patroni)

```bash
# Crea namespace database
kubectl create namespace database

# Installa Helm (se non già fatto)
# Su Raspberry/PC Linux:
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod 700 get_helm.sh
./get_helm.sh

# Installa etcd cluster (3 repliche)
# Aggiungi repository etcd-operator (alternativa)
# O usa manifest manuale

# Opzione A: StatefulSet Manuale (PIÙ SEMPLICE)
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: etcd-headless
  namespace: database
spec:
  clusterIP: None
  publishNotReadyAddresses: true
  ports:
  - name: client
    port: 2379
    targetPort: 2379
  - name: peer
    port: 2380
    targetPort: 2380
  selector:
    app: etcd
---
apiVersion: v1
kind: Service
metadata:
  name: etcd
  namespace: database
spec:
  type: ClusterIP
  ports:
  - name: client
    port: 2379
    targetPort: 2379
  selector:
    app: etcd
---
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: etcd
  namespace: database
spec:
  serviceName: etcd-headless
  replicas: 3
  podManagementPolicy: Parallel
  selector:
    matchLabels:
      app: etcd
  template:
    metadata:
      labels:
        app: etcd
    spec:
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            podAffinityTerm:
              labelSelector:
                matchExpressions:
                - key: app
                  operator: In
                  values:
                  - etcd
              topologyKey: kubernetes.io/hostname
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: node-role.kubernetes.io/witness
                operator: DoesNotExist
      containers:
      - name: etcd
        image: docker.io/bitnami/etcd:3.5.15
        ports:
        - containerPort: 2379
          name: client
        - containerPort: 2380
          name: peer
        command:
        - /bin/sh
        - -c
        - |
          HOSTNAME=$(hostname)
          DOMAIN="etcd-headless.database.svc.cluster.local"

          # Aspetta DNS per tutti i membri
          echo "Waiting for DNS resolution..."
          for i in 0 1 2; do
            until nslookup etcd-${i}.${DOMAIN}; do
              echo "Waiting for etcd-${i} DNS..."
              sleep 2
            done
            echo "etcd-${i} DNS resolved"
          done

          echo "Starting etcd as ${HOSTNAME}"
          exec /usr/local/bin/etcd \
            --name=${HOSTNAME} \
            --listen-peer-urls=http://0.0.0.0:2380 \
            --listen-client-urls=http://0.0.0.0:2379 \
            --advertise-client-urls=http://${HOSTNAME}.${DOMAIN}:2379 \
            --initial-advertise-peer-urls=http://${HOSTNAME}.${DOMAIN}:2380 \
            --initial-cluster-token=etcd-cluster \
            --initial-cluster=etcd-0=http://etcd-0.${DOMAIN}:2380,etcd-1=http://etcd-1.${DOMAIN}:2380,etcd-2=http://etcd-2.${DOMAIN}:2380 \
            --initial-cluster-state=new \
            --data-dir=/var/lib/etcd
        env:
        - name: ETCDCTL_API
          value: "3"
        volumeMounts:
        - name: data
          mountPath: /var/lib/etcd
        resources:
          requests:
            memory: "128Mi"
            cpu: "100m"
          limits:
            memory: "512Mi"
            cpu: "500m"
        livenessProbe:
          exec:
            command:
            - /bin/sh
            - -c
            - /usr/local/bin/etcdctl endpoint health
          initialDelaySeconds: 60
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 3
        readinessProbe:
          exec:
            command:
            - /bin/sh
            - -c
            - /usr/local/bin/etcdctl endpoint health
          initialDelaySeconds: 30
          periodSeconds: 10
          timeoutSeconds: 5
          failureThreshold: 3
  volumeClaimTemplates:
  - metadata:
      name: data
    spec:
      accessModes: ["ReadWriteOnce"]
      storageClassName: longhorn-replicated
      resources:
        requests:
          storage: 2Gi
EOF

# Verifica
kubectl get pods -n database
# Attendi che tutti e 3 gli etcd siano Running

# Test etcd
kubectl exec -n database etcd-0 -- etcdctl member list
```

---

## 🗄️ Configurazione Cluster

### 1. Deploy Patroni + PostgreSQL

#### ConfigMap Patroni

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: patroni-config
  namespace: database
data:
  PATRONI_SCOPE: postgres-cluster
  PATRONI_NAMESPACE: database
  PATRONI_NAME: patroni
  PATRONI_KUBERNETES_LABELS: '{"application": "patroni", "cluster-name": "postgres-cluster"}'
  PATRONI_KUBERNETES_NAMESPACE: database
  PATRONI_KUBERNETES_USE_ENDPOINTS: "true"
  PATRONI_SUPERUSER_USERNAME: postgres
  PATRONI_REPLICATION_USERNAME: replicator
  PATRONI_LOG_LEVEL: INFO

  # CONFIGURAZIONE CRITICA ZERO DATA LOSS
  PATRONI_SYNCHRONOUS_MODE: "true"
  PATRONI_SYNCHRONOUS_MODE_STRICT: "true"

  # Connessione etcd
  PATRONI_ETCD3_HOSTS: "etcd-0.etcd-headless.database.svc.cluster.local:2379,etcd-1.etcd-headless.database.svc.cluster.local:2379,etcd-2.etcd-headless.database.svc.cluster.local:2379"

  # Configurazione PostgreSQL
  PATRONI_POSTGRESQL_PARAMETERS: |
    {
      "max_connections": "100",
      "shared_buffers": "256MB",
      "effective_cache_size": "1GB",
      "maintenance_work_mem": "64MB",
      "checkpoint_completion_target": "0.9",
      "wal_buffers": "16MB",
      "default_statistics_target": "100",
      "random_page_cost": "1.1",
      "effective_io_concurrency": "200",
      "work_mem": "2621kB",
      "min_wal_size": "1GB",
      "max_wal_size": "4GB",
      "max_worker_processes": "2",
      "max_parallel_workers_per_gather": "1",
      "max_parallel_workers": "2",
      "max_parallel_maintenance_workers": "1",
      "wal_level": "replica",
      "max_wal_senders": "10",
      "max_replication_slots": "10",
      "hot_standby": "on",
      "wal_log_hints": "on",
      "synchronous_commit": "on",
      "synchronous_standby_names": "ANY 1 (*)"
    }
EOF
```

#### Secret per Password

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: patroni-secrets
  namespace: database
type: Opaque
stringData:
  PATRONI_SUPERUSER_PASSWORD: "ruttoin0!A"
  PATRONI_REPLICATION_PASSWORD: "rappino1!X"
  PATRONI_admin_PASSWORD: "caccino7H9!"
EOF
```

**⚠️ IMPORTANTE: Cambia queste password!**

#### RBAC per Patroni

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: patroni
  namespace: database
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: patroni
  namespace: database
rules:
- apiGroups: [""]
  resources: ["configmaps"]
  verbs: ["create", "get", "list", "patch", "update", "watch", "delete"]
- apiGroups: [""]
  resources: ["endpoints"]
  verbs: ["create", "get", "list", "patch", "update", "watch", "delete"]
- apiGroups: [""]
  resources: ["pods"]
  verbs: ["get", "list", "watch"]
- apiGroups: [""]
  resources: ["services"]
  verbs: ["create", "get", "list", "patch", "update", "watch", "delete"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: patroni
  namespace: database
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: patroni
subjects:
- kind: ServiceAccount
  name: patroni
  namespace: database
EOF
```

#### Services per Patroni

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: patroni
  namespace: database
  labels:
    application: patroni
    cluster-name: postgres-cluster
spec:
  type: ClusterIP
  ports:
  - port: 5432
    targetPort: 5432
    protocol: TCP
    name: postgresql
  selector:
    application: patroni
    cluster-name: postgres-cluster
---
apiVersion: v1
kind: Service
metadata:
  name: patroni-headless
  namespace: database
  labels:
    application: patroni
    cluster-name: postgres-cluster
spec:
  type: ClusterIP
  clusterIP: None
  ports:
  - port: 5432
    targetPort: 5432
    protocol: TCP
    name: postgresql
  - port: 8008
    targetPort: 8008
    protocol: TCP
    name: patroni
  selector:
    application: patroni
    cluster-name: postgres-cluster
EOF
```

#### StatefulSet Patroni

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: patroni
  namespace: database
  labels:
    application: patroni
    cluster-name: postgres-cluster
spec:
  serviceName: patroni-headless
  replicas: 2
  selector:
    matchLabels:
      application: patroni
      cluster-name: postgres-cluster
  template:
    metadata:
      labels:
        application: patroni
        cluster-name: postgres-cluster
    spec:
      serviceAccountName: patroni
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
          - labelSelector:
              matchExpressions:
              - key: application
                operator: In
                values:
                - patroni
            topologyKey: kubernetes.io/hostname
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: node-role.kubernetes.io/witness
                operator: DoesNotExist
      containers:
      - name: patroni
        image: ghcr.io/zalando/spilo-15:3.1-p1
        imagePullPolicy: IfNotPresent
        ports:
        - containerPort: 5432
          protocol: TCP
          name: postgresql
        - containerPort: 8008
          protocol: TCP
          name: patroni
        env:
        - name: SCOPE
          value: postgres-cluster
        - name: PGVERSION
          value: "15"
        - name: KUBERNETES_NAMESPACE
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace
        - name: KUBERNETES_LABELS
          value: '{"application": "patroni", "cluster-name": "postgres-cluster"}'
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: POD_IP
          valueFrom:
            fieldRef:
              fieldPath: status.podIP
        - name: PGROOT
          value: /home/postgres/pgdata
        - name: PGDATA
          value: /home/postgres/pgdata/pgroot/data
        - name: ETCD3_HOSTS
          value: "etcd-0.etcd-headless.database.svc.cluster.local:2379,etcd-1.etcd-headless.database.svc.cluster.local:2379,etcd-2.etcd-headless.database.svc.cluster.local:2379"
        - name: POSTGRES_USER
          value: postgres
        - name: POSTGRES_PASSWORD
          valueFrom:
            secretKeyRef:
              name: patroni-secrets
              key: PATRONI_SUPERUSER_PASSWORD
        - name: PGUSER_REPLICATOR
          value: replicator
        - name: PGPASSWORD_REPLICATOR
          valueFrom:
            secretKeyRef:
              name: patroni-secrets
              key: PATRONI_REPLICATION_PASSWORD
        - name: PGUSER_ADMIN
          value: admin
        - name: PGPASSWORD_ADMIN
          valueFrom:
            secretKeyRef:
              name: patroni-secrets
              key: PATRONI_admin_PASSWORD
        # Configurazione sync replication
        - name: PATRONI_SYNCHRONOUS_MODE
          value: "true"
        - name: PATRONI_SYNCHRONOUS_MODE_STRICT
          value: "true"
        - name: PATRONI_POSTGRESQL_PARAMETERS
          value: '{"synchronous_commit": "on", "synchronous_standby_names": "ANY 1 (*)", "max_connections": "100"}'
        volumeMounts:
        - name: pgdata
          mountPath: /home/postgres/pgdata
        resources:
          requests:
            memory: "512Mi"
            cpu: "500m"
          limits:
            memory: "2Gi"
            cpu: "2000m"
        livenessProbe:
          httpGet:
            path: /
            port: 8008
          initialDelaySeconds: 30
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /readiness
            port: 8008
          initialDelaySeconds: 10
          periodSeconds: 10
  volumeClaimTemplates:
  - metadata:
      name: pgdata
    spec:
      accessModes: ["ReadWriteOnce"]
      storageClassName: longhorn-replicated
      resources:
        requests:
          storage: 20Gi
EOF
```

**Attendi deploy (3-5 minuti):**
```bash
kubectl get pods -n database -w
# Ctrl+C quando entrambi patroni-0 e patroni-1 sono Running
```

**Verifica cluster Patroni:**
```bash
kubectl exec -n database patroni-0 -- patronictl list

# Output atteso:
# + Cluster: postgres-cluster ------+----+-----------+
# | Member    | Host       | Role    | State     | TL | Lag in MB |
# +-----------+------------+---------+-----------+----+-----------+
# | patroni-0 | 10.42.0.5  | Leader  | running   | 1  |           |
# | patroni-1 | 10.42.1.8  | Replica | streaming | 1  |         0 |
# +-----------+------------+---------+-----------+----+-----------+
```

---

### 2. Installazione MetalLB (LoadBalancer)

```bash
# Installa MetalLB
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.14.0/config/manifests/metallb-native.yaml

# Attendi deployment
kubectl wait --namespace metallb-system \
  --for=condition=ready pod \
  --selector=app=metallb \
  --timeout=90s

# Configura IP pool (scegli range libero in Tailscale)
# Verifica IP liberi:
tailscale status
# Scegli range che non confligge, es: 100.100.100.20-30

cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: tailscale-pool
  namespace: metallb-system
spec:
  addresses:
  - 100.100.100.20-100.100.100.30
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
```

---

## 📱 Deploy Applicazioni

### 1. Vaultwarden (Password Manager)

#### Crea Database

```bash
# Connettiti al master Patroni
kubectl exec -it -n database patroni-0 -- psql -U postgres

# Esegui SQL:
CREATE DATABASE vaultwarden;
CREATE USER vaultwarden WITH PASSWORD 'as23AcX1sdf!';
GRANT ALL PRIVILEGES ON DATABASE vaultwarden TO vaultwarden;
\q
```

#### Namespace e Secret

```bash
kubectl create namespace apps

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: vaultwarden-secret
  namespace: apps
type: Opaque
stringData:
  DATABASE_URL: "postgresql://vaultwarden:as23AcX1sdf!@patroni.database.svc.cluster.local:5432/vaultwarden"
EOF
```

#### Deployment

```bash
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: vaultwarden
  namespace: apps
  labels:
    app: vaultwarden
spec:
  replicas: 2
  selector:
    matchLabels:
      app: vaultwarden
  template:
    metadata:
      labels:
        app: vaultwarden
    spec:
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
          - weight: 100
            podAffinityTerm:
              labelSelector:
                matchExpressions:
                - key: app
                  operator: In
                  values:
                  - vaultwarden
              topologyKey: kubernetes.io/hostname
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: node-role.kubernetes.io/witness
                operator: DoesNotExist
      containers:
      - name: vaultwarden
        image: vaultwarden/server:latest
        env:
        - name: DATABASE_URL
          valueFrom:
            secretKeyRef:
              name: vaultwarden-secret
              key: DATABASE_URL
        - name: WEBSOCKET_ENABLED
          value: "true"
        - name: SIGNUPS_ALLOWED
          value: "true"
        - name: DOMAIN
          value: "http://vaultwarden.internal"
        - name: ROCKET_PORT
          value: "8080"
        ports:
        - containerPort: 8080
          name: http
        resources:
          requests:
            memory: "128Mi"
            cpu: "100m"
          limits:
            memory: "512Mi"
            cpu: "500m"
        livenessProbe:
          httpGet:
            path: /alive
            port: 8080
          initialDelaySeconds: 30
          periodSeconds: 10
        readinessProbe:
          httpGet:
            path: /alive
            port: 8080
          initialDelaySeconds: 10
          periodSeconds: 5
---
apiVersion: v1
kind: Service
metadata:
  name: vaultwarden-lb
  namespace: apps
spec:
  type: LoadBalancer
  ports:
  - port: 8080
    targetPort: 8080
    protocol: TCP
  selector:
    app: vaultwarden
EOF
```

**Ottieni IP LoadBalancer:**
```bash
kubectl get svc -n apps vaultwarden-lb
# EXTERNAL-IP sarà tipo 100.100.100.20

# Salva questo IP per configurazione DNS
VAULTWARDEN_IP=$(kubectl get svc -n apps vaultwarden-lb -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "Vaultwarden IP: $VAULTWARDEN_IP"
```

---

### 2. Configurazione DNS Interno

```bash
# Estendi CoreDNS con configurazione custom
kubectl -n kube-system get configmap coredns -o yaml > /tmp/coredns-original.yaml

cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns-custom
  namespace: kube-system
data:
  internal.server: |
    internal:53 {
        errors
        cache 30
        forward . 1.1.1.1 9.9.9.9
        log

        # Vaultwarden
        template IN A internal {
            match "^vaultwarden\.internal\.$"
            answer "{{ .Name }} 10 IN A $VAULTWARDEN_IP"
            fallthrough
        }
    }
EOF

# Riavvia CoreDNS
kubectl -n kube-system rollout restart deployment coredns
```

**Configura Tailscale DNS:**
1. Vai su [Tailscale Admin Console](https://login.tailscale.com/admin/dns)
2. **DNS** → **Nameservers** → "Add nameserver" → "Custom"
3. Aggiungi IP Tailscale di Raspi1 e Raspi2:
   - `100.100.100.1`
   - `100.100.100.2`
4. **Search domains** → Aggiungi: `internal`
5. Salva

**Test DNS:**
```bash
# Da qualsiasi dispositivo Tailscale (macOS, PC, mobile)
dig vaultwarden.internal +short
# Dovrebbe restituire l'IP del LoadBalancer

curl http://vaultwarden.internal:8080/alive
# {"status":"ok"}
```

---

### 3. Monitoring con Prometheus Stack

```bash
# Aggiungi repository Prometheus
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

# Crea namespace
kubectl create namespace monitoring

# Installa stack completo
helm install prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
  --set prometheus.prometheusSpec.retention=7d \
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.accessModes[0]=ReadWriteOnce \
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.resources.requests.storage=10Gi \
  --set prometheus.prometheusSpec.storageSpec.volumeClaimTemplate.spec.storageClassName=longhorn-replicated \
  --set grafana.adminPassword=admin \
  --set grafana.persistence.enabled=true \
  --set grafana.persistence.size=5Gi \
  --set grafana.persistence.storageClassName=longhorn-replicated

# Attendi deployment (5 minuti)
kubectl get pods -n monitoring -w
```

**Accesso Grafana:**
```bash
# Port-forward
kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80

# Apri browser: http://localhost:3000
# Login: admin / admin
```

**Dashboard consigliati** (importa da Grafana UI):
- **9628**: PostgreSQL Database
- **15760**: Kubernetes Cluster Monitoring
- **15757**: Kubernetes / Views / Pods
- **12113**: Longhorn

---

## 🧪 Testing e Verifica

### Test 1: Verifica Cluster Completo

```bash
# Nodi
kubectl get nodes
# Dovresti vedere: raspi1, raspi2 (o pc), witness - tutti Ready

# Pods database
kubectl get pods -n database
# patroni-0, patroni-1 Running + etcd-0,1,2 Running

# Pods applicazioni
kubectl get pods -n apps
# vaultwarden-xxx Running (2 repliche)

# Servizi
kubectl get svc -A
# LoadBalancer EXTERNAL-IP assegnato
```

### Test 2: Verifica Replication PostgreSQL

```bash
# Status cluster Patroni
kubectl exec -n database patroni-0 -- patronictl list

# Replication lag
kubectl exec -n database patroni-0 -- psql -U postgres -c \
  "SELECT application_name, state, sync_state, sync_priority
   FROM pg_stat_replication;"

# Dovresti vedere:
# - state: streaming (entrambi)
# - sync_state: sync (almeno uno), async (l'altro)
```

### Test 3: Failover Automatico PostgreSQL

```bash
# Identifica master corrente
MASTER=$(kubectl exec -n database patroni-0 -- patronictl list | grep Leader | awk '{print $2}')
echo "Master corrente: $MASTER"

# Simula crash master
kubectl delete pod -n database patroni-0

# Osserva failover (10-20 secondi)
watch kubectl exec -n database patroni-1 -- patronictl list

# Verifica Vaultwarden ancora funzionante
curl http://vaultwarden.internal:8080/alive

# patroni-0 riavvierà automaticamente come replica
```

### Test 4: Failover Nodo Completo

```bash
# Drain Raspi1 (sposta tutti i pod)
kubectl drain raspi1 --ignore-daemonsets --delete-emptydir-data

# Verifica migrazione
kubectl get pods -A -o wide | grep -v witness

# Tutti i pod dovrebbero essere su raspi2/pc

# Verifica servizi
curl http://vaultwarden.internal:8080/alive

# Ripristina nodo
kubectl uncordon raspi1
```

### Test 5: Split-Brain Prevention

```bash
# Verifica etcd quorum
kubectl exec -n database etcd-0 -- etcdctl endpoint health --cluster

# Output mostra health di tutti e 3 i membri
# Cluster tollera failure di 1 nodo su 3
```

---

## 🔧 Manutenzione

### Backup PostgreSQL

```bash
# Backup manuale
kubectl exec -n database patroni-0 -- pg_dumpall -U postgres | gzip > backup-$(date +%Y%m%d).sql.gz

# Restore
gunzip < backup-YYYYMMDD.sql.gz | kubectl exec -i -n database patroni-0 -- psql -U postgres
```

### Backup Automatico con CronJob

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-backup-pvc
  namespace: database
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: longhorn-replicated
  resources:
    requests:
      storage: 20Gi
---
apiVersion: batch/v1
kind: CronJob
metadata:
  name: postgres-backup
  namespace: database
spec:
  schedule: "0 2 * * *"  # 2 AM ogni giorno
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 1
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: OnFailure
          containers:
          - name: backup
            image: postgres:15-alpine
            env:
            - name: PGHOST
              value: "patroni"
            - name: PGUSER
              value: "postgres"
            - name: PGPASSWORD
              valueFrom:
                secretKeyRef:
                  name: patroni-secrets
                  key: PATRONI_SUPERUSER_PASSWORD
            command:
            - /bin/sh
            - -c
            - |
              pg_dumpall | gzip > /backup/backup-\$(date +%Y%m%d-%H%M%S).sql.gz
              # Mantieni solo ultimi 7 giorni
              find /backup -name "backup-*.sql.gz" -mtime +7 -delete
              echo "Backup completato: \$(ls -lh /backup | tail -1)"
            volumeMounts:
            - name: backup-volume
              mountPath: /backup
          volumes:
          - name: backup-volume
            persistentVolumeClaim:
              claimName: postgres-backup-pvc
EOF
```

### Update Vaultwarden

```bash
# Rolling update automatico
kubectl set image deployment/vaultwarden -n apps \
  vaultwarden=vaultwarden/server:1.30.0

# Verifica rollout
kubectl rollout status deployment/vaultwarden -n apps

# Rollback se necessario
kubectl rollout undo deployment/vaultwarden -n apps
```

### Update K3s

```bash
# Su ogni nodo, uno alla volta
# Raspberry/PC Linux:
curl -sfL https://get.k3s.io | sh -

# Verifica versione
k3s --version
```

### Scale Applicazioni

```bash
# Scale Vaultwarden
kubectl scale deployment vaultwarden -n apps --replicas=3

# Scale PostgreSQL (ATTENZIONE: richiede resize volume)
kubectl scale statefulset patroni -n database --replicas=3
```

---

## 🆘 Troubleshooting

### Problema: Pod in CrashLoopBackOff

```bash
# Descrivi pod
kubectl describe pod <pod-name> -n <namespace>

# Vedi log
kubectl logs <pod-name> -n <namespace>

# Log precedente crash
kubectl logs <pod-name> -n <namespace> --previous
```

### Problema: Nodo NotReady

```bash
# Status nodo
kubectl describe node <node-name>

# Log K3s
# Su Raspberry/PC:
sudo journalctl -u k3s -f

# Riavvia K3s
sudo systemctl restart k3s
```

### Problema: PostgreSQL non risponde

```bash
# Verifica pod
kubectl get pods -n database

# Verifica cluster Patroni
kubectl exec -n database patroni-0 -- patronictl list

# Connetti direttamente
kubectl exec -it -n database patroni-0 -- psql -U postgres

# Se tutto fallisce, restart
kubectl delete pod -n database patroni-0
```

### Problema: etcd quorum perso

```bash
# Verifica membri etcd
kubectl exec -n database etcd-0 -- etcdctl member list

# Verifica health
kubectl exec -n database etcd-0 -- etcdctl endpoint health --cluster

# Se maggioranza down, recovery manuale necessario
# Contatta supporto K3s community
```

### Problema: Storage pieno

```bash
# Verifica spazio
kubectl exec -n database patroni-0 -- df -h

# Longhorn UI per vedere usage
kubectl port-forward -n longhorn-system svc/longhorn-frontend 8080:80

# Espandi PVC (se necessario)
kubectl patch pvc pgdata-patroni-0 -n database \
  -p '{"spec":{"resources":{"requests":{"storage":"30Gi"}}}}'
```

### Problema: DNS non risolve vaultwarden.internal

```bash
# Verifica CoreDNS
kubectl get pods -n kube-system -l k8s-app=kube-dns

# Test DNS dal cluster
kubectl run -it --rm debug --image=busybox --restart=Never -- nslookup vaultwarden.internal

# Verifica Tailscale DNS settings
tailscale status
# Controlla se DNS è abilitato

# Riconfigura Tailscale DNS
sudo tailscale up --accept-dns=true
```

### Problema: Witness node down

```bash
# Cluster dovrebbe continuare con 2/3 quorum
# Verifica:
kubectl get nodes
kubectl exec -n database etcd-0 -- etcdctl endpoint health --cluster

# Se witness riavviato e non si connette:
# Su witness node:
sudo systemctl restart k3s

# Se persiste, rimuovi e ri-aggiungi:
kubectl delete node witness
# Poi re-run installazione witness
```

---

## 📚 Comandi Utili

### Gestione Cluster

```bash
# Informazioni cluster
kubectl cluster-info
kubectl get nodes -o wide

# Tutti i pod
kubectl get pods -A

# Risorse per nodo
kubectl top nodes
kubectl top pods -A

# Eventi recenti
kubectl get events -A --sort-by='.lastTimestamp'

# Shell in pod
kubectl exec -it <pod-name> -n <namespace> -- /bin/bash

# Port forward
kubectl port-forward -n <namespace> svc/<service-name> <local-port>:<remote-port>
```

### Patroni

```bash
# Cluster status
kubectl exec -n database patroni-0 -- patronictl list

# Switchover manuale
kubectl exec -n database patroni-0 -- patronictl switchover postgres-cluster

# Restart replica
kubectl exec -n database patroni-1 -- patronictl restart postgres-cluster patroni-1

# Config reload
kubectl exec -n database patroni-0 -- patronictl reload postgres-cluster
```

### Backup e Restore

```bash
# Lista backup
kubectl exec -n database -c backup <backup-pod> -- ls -lh /backup

# Download backup
kubectl cp database/<backup-pod>:/backup/backup-YYYYMMDD.sql.gz ./backup-local.sql.gz

# Restore (ATTENZIONE: sovrascrive database!)
kubectl exec -n database patroni-0 -- patronictl pause postgres-cluster
gunzip < backup.sql.gz | kubectl exec -i -n database patroni-0 -- psql -U postgres
kubectl exec -n database patroni-0 -- patronictl resume postgres-cluster
```

---

## 🎯 Best Practices

1. **Cambia TUTTE le password** di default nel README
2. **Abilita firewall** su tutti i nodi (ufw/firewalld)
3. **Backup regolari** - testa anche il restore!
4. **Monitoring alerts** - configura Prometheus AlertManager
5. **Update regolari** - ma uno nodo alla volta
6. **Documentazione** - annota modifiche custom
7. **Disaster recovery plan** - scrivi procedura recovery
8. **Test failover** - almeno una volta al mese
9. **Resource limits** - imposta request/limits su tutti i pod
10. **TLS/SSL** - usa cert-manager per certificati auto

---

## 📖 Risorse

- **K3s**: https://docs.k3s.io
- **Patroni**: https://patroni.readthedocs.io
- **Longhorn**: https://longhorn.io/docs
- **Tailscale**: https://tailscale.com/kb
- **Prometheus**: https://prometheus.io/docs
- **Kubernetes**: https://kubernetes.io/docs

---

## 🤝 Supporto

- **K3s Issues**: https://github.com/k3s-io/k3s/issues
- **Patroni Issues**: https://github.com/patroni/patroni/issues
- **Community**: K3s Slack, Kubernetes Forum

---

## 📝 Note Finali

### Costi Mensili Stimati

- **Hardware esistente**: Raspberry Pi + PC = €0 (già posseduti)
- **Cloud Witness**: €0-5/mese (Oracle free tier o Hetzner)
- **Elettricità**: ~€5-10/mese (2 Raspberry Pi 24/7)
- **Totale**: €5-15/mese

### Prestazioni Attese

- **Failover PostgreSQL**: 10-20 secondi
- **Failover nodo completo**: 30-60 secondi
- **Replication lag**: < 100ms (sync), < 1s (async)
- **Query latency**: +10-30ms con sync replication
- **Backup full**: 5-10 minuti (dipende da dimensione DB)

### Limitazioni

- **2 nodi fisici**: Se entrambi Raspi down, cluster inaccessibile (witness solo etcd)
- **Bandwidth**: Tailscale limitato da upload Internet (10-50 Mbps tipico)
- **Storage**: SSD USB 3.0 più lento di SSD SATA/NVMe interno
- **Compute**: Raspberry Pi 4 adatto per carichi leggeri/medi

### Quando Espandere

Considera aggiunta di nodi se:
- CPU usage costante > 70%
- Memory usage costante > 80%
- Storage usage > 70%
- Latency applicazioni aumenta
- Vuoi aggiungere servizi pesanti (es. Nextcloud + OnlyOffice)

---

**Versione**: 1.0
**Data**: Ottobre 2024
**Autore**: Setup per ecosistema HA distribuito
**Licenza**: Uso personale

---

🎉 **Setup completato! Il tuo cluster HA è pronto.** 🎉

Per domande o problemi, consulta la sezione Troubleshooting o le risorse della community.
