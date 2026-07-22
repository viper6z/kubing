# Cilium config

Helm values for the CNI/Ingress layer on the homelab kubeadm cluster (3 EC2 nodes, 1 control-plane + 2 workers).

This is checked into git as a single source of truth for what should be running.
It is applied manually today (no GitOps controller yet), so **the discipline is
on us**: after any manual `helm upgrade`, update this file to match, or run the
drift check below before assuming the two are in sync.

## Repo setup

```bash
mkdir cilium-config && cd cilium-config
git init
# copy values.yaml and this README in
git add .
git commit -m "cilium: initial config, ingress + kube-proxy-free working"
```

Push to wherever the rest of the homelab config lives (same repo as Seal, or its own repo, doesn't matter yet).

## Applying

```bash
helm repo add cilium https://helm.cilium.io/
helm repo update

helm upgrade cilium cilium/cilium \
  --namespace kube-system \
  --version 1.19.6 \
  -f values.yaml

kubectl -n kube-system rollout status ds/cilium
kubectl -n kube-system rollout status deployment/cilium-operator
```

## Checking for drift

Since nothing enforces this file matches reality, check it by hand periodically, or before making a new change:

```bash
helm get values cilium -n kube-system -a > /tmp/live-values.yaml
diff /tmp/live-values.yaml values.yaml
```

No output means the repo and the cluster agree.

## Things that bit us, worth remembering

- **`kubeProxyReplacement: true` alone is not enough.** kube-proxy's DaemonSet has to actually be removed (`kubectl -n kube-system delete ds kube-proxy && delete cm kube-proxy`), and leftover iptables rules cleaned up on every node (`iptables-save | grep -v KUBE | iptables-restore`, run as root on each node). Running both at once silently breaks Service routing, this is what caused a cluster-wide DNS outage once already.
- **`loadbalancerMode: shared` is required for `hostNetwork.sharedListenerPort` to do anything.** The default (`dedicated`) mode expects a per-Ingress LoadBalancer Service or a per-Ingress annotation instead, and will silently ignore the shared port.
- **`k8sServiceHost`/`k8sServicePort` must point at the real control-plane IP once kube-proxy is gone**, otherwise Cilium agents can't reach the API server on startup.
- The security group only allows TCP 32080 from a trusted source (originally a single IP, now the Tailscale interface). Don't widen this to `0.0.0.0/0`.

## Not doing yet, on purpose

No Chart.yaml wrapper, no Kustomize overlay, no ArgoCD/Flux. This is just the values file kept honest in git. Revisit once the rest of the workloads (FreshRSS, Postgres, StorageClass) are also stable enough to be worth putting under a real GitOps controller.
