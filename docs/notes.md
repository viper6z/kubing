# Phase 1 — Control plane & the controller pattern

## kubectl apply → etcd

- **kubectl apply = validate + persist to etcd, return 201. Nothing is running yet.**
- Request path through the apiserver: authentication → authorization → admission → validation → persist.

## etcd & watches

- The clients in the clusters that watch etcd open a "watch" to the api server.
- "Kubernetes supports efficient change notifications on resources via watches: in the Kubernetes API, watch is a verb that is used to track changes to an object in Kubernetes as a stream. It is used for the efficient detection of changes."
- Client loses watch connection, how does it keep track? Every object carries a resourceVersion; you reconnect with `watch?resourceVersion=N` and the apiserver replays everything after N. You lag, you don't lose.

## Deployment → ReplicaSet → Pod

- Deployment owns the ReplicaSet, ReplicaSet owns the Pods.
- The replicaset's selector is the labels the pod template carries plus the pod-template-hash.
- Anything you change at the pod level abstraction will create a new replicaset — because pod-template-hash is a hash of `spec.template`, so changing anything under the template changes the hash → new RS.
- But change the replicas or anything at the deployment level will not create a new replicaset.

## Scheduler

- Scheduling in k8s: match pods to nodes.
- The scheduler finds feasible Nodes for a Pod and then runs a set of functions to score the feasible Nodes and picks a Node with the highest score among the feasible ones to run the Pod. The scheduler then notifies the API server about this decision in a process called binding.

## Kubelet

- Kubelet watches the api server for pods with `spec.nodeName` bound to it.
- Kubelet reports back to the api server pod status.
- So when i run `kubectl get pods` — that info comes from the kubelet, indirectly.
- What does the kubelet need to start the pod? The pod spec. Which contains the image, compute specifics, volume mounts, etc.
- The kubelet doesn't start containers itself, drives containerd over CRI, and containerd (via runc) does the actual work.

## CRDs & operators

- What is a crd? Custom resource, like a replicaset, or deployment but custom. What does a crd need? Its own controller, aka operator. The operator acts like a normal controller as it has a watch for its custom resource, but it can do special things that is programmed into the operator. Cilium operator for example has a lot of custom resources it deals with like endpoints ip pools etc.
- An operator encodes "operational knowledge", failover, backups, ordered startup, upgrades, the stuff a human operator would do, as a control loop. And its scope is bounded by RBAC: it can only do what its ServiceAccount is granted, enforced by the apiserver on every call.

## Control plane bootstrap

- How does etcd, scheduler, kube controller manager, etc start up their own pods?? Kubelet reads manifest from disk, start up the pods. Then they bootstrapped.

# Phase 2 — Kubernetes networking with Cilium

Cluster: kubeadm on EC2, 3 nodes (1 CP + 2 workers), Cilium 1.19.6, kube-proxy replacement, VXLAN tunnel mode.

Legend: unmarked = mine. `[C]` = added by Claude.

---

## The organising idea

`[C]` Kubernetes is controllers holding watch streams on the **API server** (not etcd — the API server is where auth, RBAC, admission control, validation and versioning live). Each controller compares desired state to actual state and acts to close the gap, forever. None of them know about each other.

Examples seen this phase: kube-scheduler (watches unscheduled Pods + Nodes), CoreDNS (watches Services), Cilium agent (watches Services + EndpointSlices), DaemonSet controller, node controller (watches Node conditions, applies taints), cloud-controller-manager (absent — hence `<pending>` LoadBalancers).

Consequence: **declaring something never fails.** `kubectl apply` succeeds because writing the record succeeded. Whether anything acts on it is separate and asynchronous. `<pending>` means "no controller has completed this" and can't distinguish "in progress" from "nothing will ever try."

---

## 1. CNI vs Cilium

`[C]` The CNI spec covers a narrow contract: the kubelet calls a plugin binary on pod ADD/DEL, and the plugin creates the interface (veth pair), allocates an IP, and installs routes. That's it.

Not in CNI, all added by Cilium: Service/ClusterIP translation, NetworkPolicy enforcement, flow observability (Hubble). This is why NetworkPolicy objects silently do nothing on a CNI that doesn't implement enforcement — the API exists, nobody acts on it.

---

## 2. Encapsulation and routing mode

`cilium config view` showed: `routing-mode: tunnel`, `tunnel-protocol: vxlan`, `kube-proxy-replacement: true`.

**Encapsulation**: cross-node pod packet gets wrapped in a node-to-node UDP packet, because the VPC has no route for pod CIDRs.

VXLAN on Cilium uses **port 8472** — this is the Linux kernel default, *not* the IANA-assigned VXLAN port (4789). Copying a generic "allow VXLAN" firewall rule gives you 4789 and breaks the cluster.

MTU overhead due to encapsulation taking 50 bytes. This decreases throughput because to transfer a fixed number of bytes we need more packets, meaning more CPU cycles, more header processing, more encapsulation/decapsulation, more eBPF program execution etc.

`[C]` Mitigation: jumbo frames. Overhead is fixed per packet, so 50 bytes against 9000 is a much better ratio than against 1500. AWS VPC supports 9001 MTU, and my `cilium_vxlan` is already at 9001.

`[C]` Alternative to tunnel mode is `native` routing — raw pod IPs on the wire, requires the underlying network to route pod CIDRs. Tunnel is the default because it needs nothing from the network below.

**Security group failure mode**: block 8472/UDP between nodes and same-node traffic keeps working, node-to-node on other ports keeps working, pod-to-internet keeps working — but cross-node pod traffic dies. Because CoreDNS has 2 replicas on different nodes, ~50% of DNS queries fail at random. Reads as an application bug, not a firewall problem.

`[C]` Decap chain on the receiving node: NIC accepts an ordinary UDP datagram → kernel sees dst port 8472 → hands it to `cilium_vxlan` → headers stripped → eBPF looks up the inner dst in the local endpoint map → delivers straight to the pod's veth. Cilium also carries the **security identity** in the encapsulation, so the receiving node can enforce policy without reverse-mapping the IP.

---

## 3. Two address ranges

- **172.x** — pod CIDR. Real, configured on interfaces, ephemeral, dies with the pod.
- **10.96.0.0/12** — service CIDR. Fictional, on no interface anywhere, stable for the life of the Service.

`[C]` It's a **/12**, so it spans 10.96.0.0–10.111.255.255. My Services are at 10.106.150.144 and 10.111.238.133 — don't pattern-match on "10.96".

`[C]` The service range never goes on the wire, so it doesn't have to be routable by anything and could overlap with real VPC addresses harmlessly.

---

## 4. Services / ClusterIP

**Why nothing owns a ClusterIP**: no load balancer process exists; every node fakes the address locally and rewrites it at the socket. The address is a lookup key, not a location.

**The rewrite**: eBPF fires during the `connect()` syscall and overwrites the destination *argument*, before the kernel builds the socket. So the socket record is created with the pod IP and never contains the ClusterIP.

So when my FreshRSS pod sends something with the destination IP of the Postgres Service, eBPF swaps the service address to a pod address. Then a socket is created between the 2 real addresses. When the return packet comes, its source is the real pod IP and destination is also a real pod IP, so it matches the socket.

**Without eBPF**, the kernel would build a socket from a real IP to a fake one, and nothing would ever answer.

`[C]` Only the *destination* was ever fictional — the source is the pod's real address from the start.

**What kube-proxy replacement replaced**: iptables DNAT in-flight → eBPF rewrite at the syscall, before the packet exists. kube-proxy needs conntrack to un-DNAT the reply; socket-level doesn't, because there was never a mismatch.

`[C]` Verify with `ss -tn` inside a pod: the peer column shows the pod IP, not the ClusterIP.

`[C]` UDP is messier — a datagram socket may not be connected, so Cilium keeps a reverse mapping for those. Version-sensitive; check 1.19 docs.

---

## 5. Agent failure

The Cilium agent is the bookkeeper. The agent writes to the maps that the kernel program uses. eBPF programs and their maps are **kernel state, not agent state** — the agent writes and walks away.

Tested by killing the agent while a curl loop ran: traffic kept flowing, returned 302s throughout.

**When I turn off all the Cilium agents and try to start a new pod, it doesn't even get assigned to a node.** The scheduler's filter operation didn't return any nodes to score, because the kubelet flips the node to `NotReady` when the CNI plugin is unavailable, and the node controller then taints it `not-ready:NoSchedule`.

`[C]` Note the failure is one stage *earlier* than expected — the pod never reaches the CNI call, it never gets scheduled at all. Existing pods keep running because they tolerate `not-ready:NoExecute` for 300s.

The scheduler has a watch on anything that can influence its node selection operation. `[C]` — and when a node's taint changes, pods sitting in the unschedulable queue get moved back to the active queue and retried. Reads are what you watch; writes are what you act on.

**Summary**: reads survive an agent death, writes don't. Existing connections and new connections to known Services work. New pods can't be networked, new Services get no map entries, and if a backend pod moves the node keeps sending to the dead IP.

---

## 6. NodePort / LoadBalancer

`[C]` **NodePort**: eBPF intercepts inbound at the network device and checks the port against a map. Nothing is listening — no process, no socket on the node. Range 30000–32767 by default, and **every node answers**, including nodes running no backing pod.

`[C]` **LoadBalancer**: a *request* for external infrastructure. Kubernetes can't call the AWS API — no credentials, no knowledge AWS exists. Needs a cloud-controller-manager to fulfil it. I don't have one, so `EXTERNAL-IP` stays `<pending>` forever, with no error.

`[C]` The types stack: a LoadBalancer Service also has a NodePort, which also has a ClusterIP. The AWS load balancer's job is only "pick a healthy node"; once the packet lands anywhere, eBPF finds the pod.

`[C]` NodePorts stay directly reachable even behind a load balancer — restricting them is a security-group job, not a Kubernetes one. Mine is scoped to `var.admin_cidr` on 32080 only.

---

## 7. DNS

**How the pod knows where to ask**: the kubelet reads `clusterDNS: 10.96.0.10` and `clusterDomain: cluster.local` from `/var/lib/kubelet/config.yaml` on the node, and writes `/etc/resolv.conf` into the pod at creation. The pod just reads a file.

My resolv.conf:
```
search freshrss.svc.cluster.local svc.cluster.local cluster.local eu-north-1.compute.internal
nameserver 10.96.0.10
options ndots:5
```

`[C]` First three search domains are generated from namespace + cluster domain. The fourth is AWS's internal DNS, inherited from the node's own resolv.conf via DHCP.

**`ndots:5`** means: if the name asked for contains 5 or more dots, it's treated as fully qualified and queried as-is with no search list. Fewer than 5 dots, and the search list is tried first.

When I looked at Hubble for a `github.com` lookup from a pod, there were **5 queries** — 4 NXDOMAINs walking the search list, then the real one. `postgres` takes 1, because the first search domain hits.

`[C]` Fixes: trailing dot (`github.com.`) to force FQDN, lower `ndots` via `dnsConfig` in the pod spec, or NodeLocal DNSCache. The threshold is 5 because the longest cluster name form has 4 dots.

`[C]` **CoreDNS holds no records.** It watches the API server and derives names from object name + namespace: `<service>.<namespace>.svc.<cluster-domain>`. Nothing is stored; it's computed. `dnsPolicy: ClusterFirst` (the default) means cluster names answered locally, everything else forwarded upstream. `dnsPolicy: Default` is *not* the default and skips cluster DNS entirely.

`[C]` The client-side resolver does the search-domain appending, not CoreDNS. CoreDNS only ever receives fully-qualified names.

---

## 8. NetworkPolicy

Default is **open** — no policy means all pod-to-pod traffic allowed, across namespaces included.

**Selection creates the deny.** Once a policy selects a pod for a direction, everything not explicitly allowed becomes denied. There is no deny rule in the standard resource and you can't write one.

**Isolation is per-direction.** An ingress policy leaves egress completely open. (Trap: write an ingress policy, feel secure, compromised pod exfiltrates freely.)

`[C]` **Policies are additive** — two policies selecting the same pod produce the union of allowed sources, never an intersection. No ordering, no precedence, no specificity tiebreak. The only way to make something more restrictive is to remove a policy. `ipBlock.except` narrows one rule, not other policies.

`[C]` A `podSelector` in a `from` block with no `namespaceSelector` matches **only the policy's own namespace**.

My policy:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: freshrss-postgres
  namespace: freshrss
spec:
  podSelector:
    matchLabels:
      app.kubernetes.io/name: postgres
  policyTypes:
    - Ingress
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: freshrss
    ports:
    - protocol: TCP
      port: 5432
```

This allows only pods with label `app=freshrss` to reach pods with label `app.kubernetes.io/name=postgres` on port 5432.

Note the two apps use different label conventions — mismatching those keys silently selects nothing, with no error and no event.

**Verified**: `walktest` (no matching label) timed out. `policytest` — same image, same command, `--labels='app=freshrss'` — went through. Different identity numbers in Hubble (6702 vs 19283).

`[C]` **A drop looks like a timeout, not a refusal.** RST = closed port. Silence = policy drop.

`[C]` Enforcement runs on **identity derived from labels**, not names or IPs. Anyone who can create a pod in the namespace can assume that identity — the policy is only as strong as RBAC.

`[C]` CiliumNetworkPolicy adds: deny rules (deny wins over allow, inverting the model), L7 rules (HTTP methods/paths, enforced via Envoy), and FQDN/DNS-aware egress. Deny doesn't work at L7 or with FQDNs. `CiliumClusterwideNetworkPolicy` for cross-namespace.

---

## 9. Ingress

`[C]` An **Ingress** is an object — a declaration. An **ingress controller** is a running program that watches Ingress objects and programs a proxy. Same relationship as LoadBalancer Service ↔ cloud-controller-manager.

Mine: `kubectl get ingressclass` → `cilium.io/ingress-controller`, and the proxy doing the work is the `cilium-envoy` DaemonSet. `ADDRESS` is empty because it wants a LoadBalancer Service and I have no CCM — works anyway via NodePort 32080.

`[C]` **A reverse proxy terminates.** The browser's TCP connection *ends* at Envoy; Envoy reads the HTTP request and opens a **separate** connection to the Service. Two connections. That's what lets it route on hostname and path — a NodePort can't, because nothing reads the request.

**External path**: browser → security group allows my CIDR on 32080 → eBPF intercepts at the device, NodePort map lookup, rewrites destination to Envoy → Envoy terminates, reads HTTP, matches the Ingress rules → Envoy calls `connect()` to the FreshRSS ClusterIP → eBPF rewrites at the socket to a pod IP → same node = veth-to-veth, other node = VXLAN.

---

## 10. Hubble

`hubble observe -P` — `-P` does the port-forward itself, no stray background job to lose.

**Observation points** tell you where in the datapath the packet was seen:
- `from-endpoint` — just left a local pod's veth
- `to-overlay` — being handed to VXLAN, about to cross to another node
- `to-endpoint` — delivered into a local pod's veth
- `to-stack` / `to-network` — host stack / physical interface

**`to-overlay` present = crossed nodes. Absent = same node.** You can read pod placement straight out of flow logs.

`[C]` `to-overlay` on the sender with no matching `to-endpoint` on the receiver = packets entering the tunnel and never arriving. That's the blocked-VXLAN signature.

**No ClusterIP ever appears in Hubble output** — the rewrite happens before the datapath sees anything.

The `ID:` numbers are security identities, derived from labels. That's what policy operates on.

Useful filters: `-n <ns>`, `--port`, `--from-pod`, `--to-pod`, `--verdict DROPPED`, `--last N`.

`[C]` `--verdict DROPPED` is noisy — ICMPv6 router solicitations to `ff02::2` get dropped constantly as "Unsupported L3 protocol" on an IPv4-only cluster. Background hum, ignore it.

---

## Real incidents

### Tailscale broke the control plane node

Symptom chain, top to bottom: FreshRSS pod stuck ContainerCreating → EBS volume wouldn't attach → CSI driver couldn't resolve `ec2.eu-north-1.amazonaws.com` → DNS queries timing out ~50% → one CoreDNS replica unreachable → Cilium agent on the control plane unreachable → **Node object advertising the Tailscale address (100.115.215.22) instead of the VPC address (10.42.1.204)**.

Five layers between the fault and the symptom, and none of the errors pointed at the cause.

Two *independent* heuristics both picked the wrong interface:

1. **kubelet** — with no `--node-ip`, it picks the address on the interface with the default route. Fixed with `KUBELET_EXTRA_ARGS="--node-ip=10.42.1.204"` in `/etc/default/kubelet`, then `systemctl restart kubelet`.
2. **Cilium device detection** — attached to both `ens5` and `tailscale0`, picked the Tailscale one as primary, and derived MTU 1280 from it instead of 9001. Fixed with `helm upgrade ... --reuse-values --set devices='{ens+}'`.

Fixing one does not fix the other. `[C]` Treat "node has more than one global-scope address" as the trigger to pin both explicitly.

`[C]` Verify: `cilium-dbg status --verbose | grep -A3 Devices` should list only `ens5`; `ip -d link show cilium_host` should be 9001; `hubble status` should show 3 nodes with none unavailable.

### IMDSv2 hop limit

`http-put-response-hop-limit` had to be **3** for pods to reach IMDSv2. Default 1, and 2 wasn't enough. Each namespace boundary crossing is a forwarding step that decrements TTL, and Cilium adds an extra routing layer (`cilium_host`/`cilium_net`) beyond the pod veth.

Hit this via the EBS CSI driver, which needs IMDS for instance ID and AZ. AWS docs now mention non-VPC-CNI plugins needing a higher limit — I filed the issue that added that.

`[C]` Alternative fix: `hostNetwork: true` — no veth, no forwarding step, default limit works. Costs the pod the node's full network view.

### RWO volume blocks rolling updates

`FailedAttachVolume: Multi-Attach error` — the PVC is ReadWriteOnce, but RollingUpdate wants the new pod up before killing the old one. Both need the volume, neither can start.

`[C]` Fix: `strategy: Recreate` in the Deployment spec. Phase 3 territory. Escape hatch when stuck: `kubectl scale --replicas=0`, wait, scale back up — deleting pods doesn't work because the ReplicaSet recreates them.

---

## Command reference

```bash
# config, not health — routing mode and kube-proxy replacement live here
cilium config view | grep -iE 'routing-mode|tunnel|kube-proxy'

# node-level things need the agent (hostNetwork: true) or SSH
kubectl -n kube-system exec ds/cilium -- ip -d link show cilium_vxlan
kubectl -n kube-system exec ds/cilium -- cilium-dbg status --verbose

# throwaway debug pod
kubectl run -n <ns> test --rm -it --image=nicolaka/netshoot --restart=Never -- <cmd>

# pin to a node (bypasses the scheduler, ignores taints)
--overrides='{"spec":{"nodeName":"ip-10-42-1-158"}}'

# assume an identity by label
--labels='app=freshrss'

# validate without applying
kubectl apply -f x.yaml --dry-run=server

# flows
hubble observe -P -n freshrss --port 5432 --last 20
hubble observe -P --verdict DROPPED --follow
```

---

## Still open

- `nodePort.addresses` not set — Cilium may still pick oddly for NodePort on multi-address nodes.
- Envoy's `policy-verdict:none TRAFFIC_DIRECTION_UNKNOWN` line — need to check 1.19 Hubble docs for what the match-type values mean.
- Gateway API — awareness only, out of scope this phase.

# Phase 3: storage, CSI, and stateful workloads

## 1. Why CSI exists

Storage drivers used to live inside the Kubernetes source tree: the AWS EBS driver, the GCE PD driver, Ceph, all of it compiled into kubelet and controller-manager. "In-tree."

That meant:

- A bug in the EBS driver got fixed on Kubernetes' release schedule, not AWS's. You waited for a minor release.
- Every cluster shipped every vendor's driver whether you used it or not. Bloat, and a bigger attack surface.
- Vendor code ran inside core Kubernetes components. A bad driver could take down kubelet.
- Adding support for new storage meant getting a PR merged into Kubernetes itself.

## 2. CSI architecture: two workloads

**controller Deployment**: one pod, runs anywhere. Contains `ebs-plugin` (the driver, holds AWS creds) plus sidecars: `csi-provisioner`, `csi-attacher`, `csi-resizer`, `livenessprobe`. `csi-snapshotter` is a fifth, not installed on mine.

Sidecars are generic k8s code, same on every cloud. Each watches one API object type and calls gRPC on the driver container next to it. Only the driver knows what EBS is. Swap the driver, keep the sidecars.

**node DaemonSet (`ebs-csi-node`)**: one pod per node, privileged, host filesystem mounted in. Same image, different role. Exists because `mkfs` and `mount` are kernel operations on a specific machine, and there's no remote version. The controller can be anywhere because everything it does is an API call to AWS.

kubelet calls the node plugin directly over a local unix socket, no sidecar, because both are already on the machine. Two calls: `NodeStageVolume` (format if blank, mount to a staging path) then `NodePublishVolume` (bind-mount into the pod's directory).

## 3. PV, PVC, StorageClass

**StorageClass**: a template, created by you (or a Helm chart), once. It names the driver, the parameters, the reclaim policy, the binding mode. Mine is `ebs-gp3-retain`. It doesn't represent any actual storage; it's instructions for how to make some.

**PVC**: a request, created by you, per workload. "I want 20Gi, RWO, from this class." It's the only storage object an application author should have to write. Deliberately ignorant of EBS.

**PV**: the actual thing. Cluster-scoped, created by the provisioner in dynamic provisioning, and it holds the EBS volume ID. This is where the abstraction stops and AWS starts.

**Binding** is the PV controller matching a Pending PVC to a suitable PV (right size, right access mode, right class) and writing the reference into both. Exclusive and permanent: one PV to one PVC, and it doesn't get reused for something else while bound.

## 4. Dynamic provisioning, end to end

```
scheduling → PVC → provisioner → CreateVolume → PV → binding →
VolumeAttachment → attacher → AttachVolume → kubelet → node plugin → mount
```

PVC gets created. If it's `WaitForFirstConsumer` it sits Pending until a pod gets scheduled on a node by kube-scheduler. csi-provisioner watches for PVCs with a StorageClass whose provisioner is `ebs.csi.aws.com`. It makes a gRPC call `CreateVolume` to the driver pod that talks to the AWS API and makes the volume exist in AWS. csi-provisioner creates a PersistentVolume object in etcd through the API server. The PV controller inside kube-controller-manager has a watch for this and creates the PVC to PV binding.

Then AttachDetach controller sees a pod scheduled with a bound PVC on a node. It creates a VolumeAttachment object naming the volume and the node. csi-attacher watches VolumeAttachments, sees the new one, and makes a gRPC call to the driver, and the driver calls the AWS API to attach the volume to the right node. It marks the VolumeAttachment `attached: true`, which kubelet on the node watches for, and calls the node plugin that formats the volume if blank and bind mounts to the pod's directory.

## 5. The EBS topology trap

If you have a multi-AZ cluster and put `volumeBindingMode: Immediate` on the StorageClass, that can bite you, because the EBS volume gets created before a node has been scheduled for the pod, meaning now only nodes from that AZ can get assigned the pod from the scheduler.

## 6. Access modes

RWO counts nodes, not pods. Two pods on the same node can both mount it; two pods on different nodes cannot.

RWX is not supported on EBS. If you want a volume server thing that all nodes can reach, that's EFS.

## 7. Reclaim policies, expansion, snapshots

### Reclaim policies

**Retain**: when the PVC is deleted the PV remains and goes to `Released`. Released PVs cannot be bound, because the old PVC's identity is still stamped on the PV in `claimRef`. To reuse: patch `claimRef` to null, PV goes `Available`. Deleting the PV object does NOT delete the EBS volume under Retain; it just loses your only record of the volume ID. Orphaned volumes keep billing and nothing in the cluster tells you.

**Delete**: deletes the PV and the storage asset on the external infra.

### Expansion

If `allowVolumeExpansion` is set to true you can edit the PVC to specify a larger size and the PV will be resized.

### Snapshots

It's a CRD. Needs the snapshot controller and the `csi-snapshotter` sidecar for the driver.

As part of the deployment process of VolumeSnapshot, the Kubernetes team provides a snapshot controller to be deployed into the control plane, and a sidecar helper container called `csi-snapshotter` to be deployed together with the CSI driver. The snapshot controller watches VolumeSnapshot and VolumeSnapshotContent objects and is responsible for the creation and deletion of VolumeSnapshotContent objects. The sidecar `csi-snapshotter` watches VolumeSnapshotContent objects and triggers CreateSnapshot and DeleteSnapshot operations against a CSI endpoint.

## 8. Node failure semantics

| Time | What happens |
|---|---|
| 0s | node dies, heartbeats stop |
| ~40s | node controller marks it `NotReady`, adds the unreachable taint |
| ~5min later | taint toleration expires, pods get a `deletionTimestamp` |
| | pods enter `Terminating` and stay there, because no kubelet can confirm they stopped |
| | meanwhile the Deployment/StatefulSet sees the count drop and schedules replacements elsewhere |
| ~6min after detach requested | volume force-detaches, replacement pod can mount |

## 9. StatefulSet vs Deployment + PVC

### Deployment + PVC

- A Deployment has one pod template with one `volumes` section. Every replica references the same PVC, so 2 or more replicas need to be on the same node, or if pods land on another node we get a multi-attach error.
- When you do `RollingUpdate`, you try to bring up the new pod then terminate the old one, but in this instance it will cause a deadlock, because the new pod can't access the same volume as the old one, and the old one won't terminate until the new one is ready, which it won't be as long as it can't attach. The fix is `strategy: Recreate`, which will accept downtime and kill the old pod first, before starting the new one.

### StatefulSet

- Pods get stable identity, like `postgres-0` and `postgres-1`. The name survives rescheduling. A StatefulSet creates 1 PVC per replica so each pod owns its own volume permanently, so no fighting for disk. PVCs outlive the pods, so when `postgres-0` gets recreated the PVC will remain for it.

### volumeClaimTemplates naming

`volumeClaimTemplates` generate PVC names as `<template-name>-<sts-name>-<ordinal>`. Template `data` + sts `postgres` gives `data-postgres-0`.

Adoption is pure string matching. If a PVC already exists at that name the StatefulSet uses it, otherwise it creates one. That's the whole mechanism for reconnecting a StatefulSet to existing data: pre-create a PVC at the generated name with `volumeName` pointing at the PV.

Three places must agree: volumeClaimTemplate name, volumeMount name, and the prefix on the pre-created PVC.

### Migration log: postgres from Deployment to StatefulSet

```
vol-014e28c1ea9d62ddf
pvc-65109b10-e472-447c-b4f3-feefc4d38ce4  →  vol-014e28c1ea9d62ddf  (5Gi)
```

```bash
kubectl scale deploy postgres -n freshrss --replicas=0
# delete two orphan volumes in EBS, then delete their PVs in kubectl
kubectl delete pvc postgres-data -n freshrss
kubectl patch pv pvc-65109b10-e472-447c-b4f3-feefc4d38ce4 -p '{"spec":{"claimRef":null}}'
```

## 10. In-cluster Postgres vs RDS

RDS premium (~2-3x raw EC2) buys: automated backups + PITR, minor version patching, Multi-AZ failover in ~1 min with committed transactions intact, metrics, storage autoscaling. None are hard individually, but all have to be built, kept working, and tested.

Give up: superuser, extensions outside AWS's allowlist, upgrade timing, lock-in.

My current setup for comparison: no replication, no WAL archiving, no backups, ~6 min recovery from node failure.

Third option, and naming it matters: an operator (CloudNativePG, Zalando) closes most of the gap with replication, failover, S3 backup, and PITR, as a controller doing reconciliation. "StatefulSet vs RDS" is a false binary.

**RDS when**: small team, no DBA, db is system of record.

**In-cluster when**: many databases so the premium compounds, need blocked extensions, multi-cloud, or dev/test where failure cost is near zero.
