# K3s HA Cluster - Quick Start Guide

## Prerequisites Checklist

- [ ] Tailscale installed on all nodes
- [ ] Tailscale connected (`tailscale up`)
- [ ] SSH access to all nodes (root or sudo)
- [ ] At least 20GB storage on master nodes
- [ ] Control machine has Tailscale and optionally kubectl

## Installation Steps

### Step 1: Install First Master

```bash
./install-cluster.sh
```

1. Select first master device
2. Choose: **Master node**
3. Choose: **First master (initialize cluster)**
4. Provide SSH credentials
5. **SAVE THE TOKEN DISPLAYED!**

### Step 2: Install Second Master

```bash
./install-cluster.sh
```

1. Select second master device
2. Choose: **Master node**
3. Choose: **Additional master (join existing cluster)**
4. Provide the token from Step 1
5. Provide first master's Tailscale IP

### Step 3: Install Witness

```bash
./install-cluster.sh
```

1. Select witness device (cloud VM)
2. Choose: **Witness node**
3. Provide the token from Step 1
4. Provide first master's Tailscale IP

### Step 4: Verify Cluster

```bash
kubectl get nodes
```

Expected: 3 nodes, all Ready

### Step 5: Deploy Services

```bash
# 1. Storage (REQUIRED FIRST)
./scripts/deploy-longhorn.sh

# 2. LoadBalancer
./scripts/deploy-metallb.sh

# 3. Database
./scripts/deploy-database.sh

# 4. Demo app (optional)
./scripts/deploy-vaultwarden.sh

# 5. Monitoring (optional)
./scripts/deploy-monitoring.sh
```

## Verify Deployment

```bash
# Check all pods
kubectl get pods -A

# Check PostgreSQL cluster
kubectl exec -n database patroni-0 -- patronictl list

# Check etcd health
kubectl exec -n database etcd-0 -- etcdctl endpoint health --cluster

# Get Vaultwarden LoadBalancer IP
kubectl get svc -n apps vaultwarden-lb
```

## Access Services

### Grafana
```bash
kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80
# http://localhost:3000 (admin/admin)
```

### Longhorn
```bash
kubectl port-forward -n longhorn-system svc/longhorn-frontend 8080:80
# http://localhost:8080
```

### PostgreSQL
```bash
kubectl exec -it -n database patroni-0 -- psql -U postgres
```

## Common Commands

```bash
# Cluster info
kubectl cluster-info
kubectl get nodes -o wide

# All pods
kubectl get pods -A

# Pod logs
kubectl logs -n <namespace> <pod-name>

# Shell in pod
kubectl exec -it -n <namespace> <pod-name> -- /bin/bash

# Delete pod (force restart)
kubectl delete pod -n <namespace> <pod-name>

# Describe resource
kubectl describe <resource> <name> -n <namespace>
```

## Troubleshooting

### Node not joining

1. Check Tailscale: `tailscale status`
2. Check K3s logs: `sudo journalctl -u k3s -f`
3. Verify token is correct
4. Verify first master IP is reachable

### Pods not starting

1. Check events: `kubectl get events -A`
2. Describe pod: `kubectl describe pod <name> -n <namespace>`
3. Check logs: `kubectl logs <name> -n <namespace>`

### Storage issues

1. Check Longhorn: `kubectl get pods -n longhorn-system`
2. Check StorageClass: `kubectl get storageclass`
3. Access Longhorn UI for details

## Next Steps

1. **Change passwords** in manifests
2. Set up automated backups
3. Configure Prometheus alerts
4. Test failover scenarios
5. Add SSL/TLS certificates

## Important Files

- `k3s-token.txt` - Save this! Needed for adding nodes
- `manifests/database/03-patroni-secrets.yaml` - Change passwords!
- `manifests/network/metallb-ippool.yaml` - Customize IP range

## Support

See [README.md](README.md) for detailed documentation.
