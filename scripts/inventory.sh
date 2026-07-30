#!/usr/bin/env bash
#
# inventory.sh: snapshot cluster state before migrating to Flux.
# Usage: ./inventory.sh [output-dir]
#
# SENSITIVE OUTPUT. helm/*.values-user.yaml contains the values you supplied at
# install time, which for kube-prometheus-stack means your Grafana admin
# password and Discord webhook in plaintext. The script writes a .gitignore
# excluding the whole snapshot directory. Leave it there.
#
# Kubernetes Secret contents are never dumped. Only names, types, and key names.
#
# The node section needs root to read /etc/kubernetes/manifests, and only works
# on a control plane node. If you run the whole script under sudo, pass your
# kubeconfig through: sudo KUBECONFIG="$HOME/.kube/config" ./inventory.sh

set -uo pipefail

OUT="${1:-inventory-$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUT"/{cluster,namespaces,helm}
printf '*\n' >"$OUT/.gitignore"

say() { printf '==> %s\n' "$*"; }

# Derived or per-pod objects. Noise for inventory purposes.
SKIP='^(events|endpoints|endpointslices|controllerrevisions|replicasets|pods|leases|ciliumendpoints|ciliumidentities|ciliumendpointslices)'

say "cluster scope"
kubectl version -o yaml >"$OUT/cluster/version.yaml" 2>&1
kubectl get nodes -o wide >"$OUT/cluster/nodes.txt" 2>&1
kubectl describe nodes >"$OUT/cluster/nodes-describe.txt" 2>&1
kubectl get ns >"$OUT/cluster/namespaces.txt" 2>&1
kubectl top nodes >"$OUT/cluster/top-nodes.txt" 2>&1

kubectl get crd -o custom-columns='NAME:.metadata.name,GROUP:.spec.group,VERSIONS:.spec.versions[*].name,SCOPE:.spec.scope' \
  >"$OUT/cluster/crds.txt" 2>&1

kubectl get storageclass -o yaml >"$OUT/cluster/storageclasses.yaml" 2>&1

# Reclaim policy and EBS volume ID per PV. Both matter later: reclaim policy
# decides whether a helm uninstall is survivable, volume ID is what Terraform
# needs if you ever want data to survive a rebuild.
kubectl get pv -o custom-columns='NAME:.metadata.name,CAP:.spec.capacity.storage,RECLAIM:.spec.persistentVolumeReclaimPolicy,PHASE:.status.phase,CLAIM_NS:.spec.claimRef.namespace,CLAIM:.spec.claimRef.name,SC:.spec.storageClassName,EBS:.spec.csi.volumeHandle' \
  >"$OUT/cluster/pv.txt" 2>&1

CLUSTER_RES=$(kubectl api-resources --verbs=list --namespaced=false -o name 2>/dev/null |
  grep -Ev "$SKIP" | paste -sd, -)
kubectl get "$CLUSTER_RES" --show-kind --ignore-not-found \
  >"$OUT/cluster/all-cluster-scoped.txt" 2>"$OUT/cluster/all-cluster-scoped.err"

say "namespaced resources"
NS_RES=$(kubectl api-resources --verbs=list --namespaced=true -o name 2>/dev/null |
  grep -Ev "$SKIP" | paste -sd, -)

for ns in $(kubectl get ns -o jsonpath='{.items[*].metadata.name}'); do
  kubectl get "$NS_RES" -n "$ns" --show-kind --ignore-not-found \
    >"$OUT/namespaces/$ns.txt" 2>"$OUT/namespaces/$ns.err"
  kubectl get pods -n "$ns" -o wide >"$OUT/namespaces/$ns.pods.txt" 2>&1
  # names, types, and key names only, never values
  kubectl get secret -n "$ns" -o go-template='{{range .items}}{{.metadata.name}}{{"\t"}}{{.type}}{{"\t"}}{{range $k,$v := .data}}{{$k}}{{" "}}{{end}}{{"\n"}}{{end}}' \
    >"$OUT/namespaces/$ns.secrets.txt" 2>&1
done

say "helm releases"
helm list -A >"$OUT/helm/releases.txt" 2>&1
helm list -A -o yaml >"$OUT/helm/releases.yaml" 2>&1

helm list -A | awk 'NR>1 {print $1, $2}' | while read -r name ns; do
  [ -n "$name" ] || continue
  helm get values "$name" -n "$ns" >"$OUT/helm/$ns.$name.values-user.yaml" 2>&1
  helm get metadata "$name" -n "$ns" >"$OUT/helm/$ns.$name.metadata.yaml" 2>&1
  helm get manifest "$name" -n "$ns" >"$OUT/helm/$ns.$name.manifest.yaml" 2>&1
done

if [ -d /etc/kubernetes/manifests ] && [ -r /etc/kubernetes/manifests ]; then
  say "node-level state"
  mkdir -p "$OUT/node"
  cp -a /etc/kubernetes/manifests/*.yaml "$OUT/node/" 2>/dev/null
  grep -rn 'bind-address' /etc/kubernetes/manifests/ >"$OUT/node/bind-address.txt" 2>&1
  # what kubeadm believes the cluster config is, versus what is on disk
  kubectl -n kube-system get cm kubeadm-config -o yaml >"$OUT/node/kubeadm-config.yaml" 2>&1
  kubeadm version -o yaml >"$OUT/node/kubeadm-version.yaml" 2>&1
else
  say "skipping node-level state (not a control plane node, or no root)"
fi

say "done: $OUT"
echo
echo "Sensitive: $OUT/helm/*.values-user.yaml"
echo "Errors, if any, are in the matching .err files."
