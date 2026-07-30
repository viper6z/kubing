## 2026-07-07

Set up the first AWS foundation for Kubing with Terraform.

Made a separate VPC/subnet/SG setup from Seal, with SSH only allowed from my current public IP and private node-to-node traffic allowed inside the SG.

Created 3 Ubuntu 24.04 EC2 instances:
- 1 control plane
- 2 workers

Used Canonical's SSM AMI lookup instead of hardcoding an AMI ID.

Validated:
- SSH from WSL into all 3 nodes
- outbound internet access from all nodes
- private connectivity between the nodes

Ran `terraform destroy` afterwards and it removed all 13 resources cleanly.

One thing to revisit before kubeadm: the default root disks were only 8 GB.

So i've now increased the root disks 20 GB.

What i am trying to understand now is the runtime stuff, basically kubernetes needs a uniform way to organize container processes into cgroups. We need a cgroups driver. Im going to choose systemd for this. I am choosing the systemd cgroup driver. Both kubelet and the container runtime use the driver to create and manage the same cgroup structure, so they agree on where each Pod and its container processes live.
See the official docs: 
"Warning:
Matching the container runtime and kubelet cgroup drivers is required or otherwise the kubelet process will fail."

Added Docker’s official apt repository on all three nodes and installed containerd.io only, not Docker Engine.

Updated /etc/containerd/config.toml to enable CRI and configure containerd to use the systemd cgroup driver with SystemdCgroup = true. Restarted containerd and verified the service and CRI plugins were active.

Enabled ipv4 packet forwarding on all, see kubernetes container runtimes.

Now its time to install the kubernetes stuff, as per the docs:
You will install these packages on all of your machines:

    kubeadm: the command to bootstrap the cluster.

    kubelet: the component that runs on all of the machines in your cluster and does things like starting pods and containers.

    kubectl: the command line util to talk to your cluster.

Following the official install instructions for debian distros for kubernetes 1.36, on all 3 machines.

Now that kubeadm is installed, we need to do the pod network setup.

The api server will be reachable on control plane VM's private IP.

Im leaning on Cilium for the CNI

Cluster Pod CIDR: 172.20.0.0/16

Cilium allocates a per-node Pod subnet, typically /24:
control plane → 172.20.0.0/24
worker-1      → 172.20.1.0/24
worker-2      → 172.20.2.0/24

Then each Pod gets one IP from the /24 assigned to the node it runs on

Quick layout of the 3 most distinct layers here : 

AWS VPC network
→ makes the VMs able to reach each other

Kubernetes API server
→ the higher-level coordination point
→ tells the cluster what should exist and records what currently exists

Pods / CNI
→ the lower-level workload and networking layer
→ actually runs workloads and gives them connectivity

The first step is just to run plainly kubeadm init

This is the output: 

Your Kubernetes control-plane has initialized successfully!

To start using your cluster, you need to run the following as a regular user:

  mkdir -p $HOME/.kube
  sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
  sudo chown $(id -u):$(id -g) $HOME/.kube/config

Alternatively, if you are the root user, you can run:

  export KUBECONFIG=/etc/kubernetes/admin.conf

## 2026-07-08 — AWS foundation rebuild validated

Rebuilt the Kubing AWS foundation from Terraform after a full destroy.

New node IPs for this run:

* control-plane: public `16.171.55.14`, private `10.42.1.181`
* worker-1: public `13.49.246.191`, private `10.42.1.34`
* worker-2: public `16.170.143.13`, private `10.42.1.162`

Validation done:

* SSH from WSL to all three Ubuntu nodes works.
* Private node-to-node networking inside `10.42.1.0/24` works.
* Outbound internet works on all nodes.
* `apt update` works on all nodes.

Decision: AWS foundation is ready for Day 0 Kubernetes bootstrap. Keep Kubernetes setup manual for now and document the path before turning it into a golden path later.

Cleanup note: this run creates live EC2 instances, so destroy them when finished with the lab session if I am not continuing.

Used my bootstrap runbook and Kubernetes docs to prepare the nodes again.

Created `scripts/validate-node.sh` as a small pre-check before `kubeadm init` / `kubeadm join`. It checks things like swap, IPv4 forwarding, containerd, and Kubernetes tools. It caught one real issue where IPv4 forwarding was not enabled on one node. kubeadm still has its own preflight checks, so the script is only a quick sanity check.

Ran `kubeadm init` on the control-plane node. kubeadm selected the private API server address `10.42.1.181`.

Configured `kubectl` for the `ubuntu` user with `/etc/kubernetes/admin.conf`.

Before installing Cilium:

* control-plane node was `NotReady`
* CoreDNS was `Pending`
* API server, etcd, scheduler, controller-manager, and kube-proxy were `Running`
* `kubectl describe node` showed `cni plugin not initialized`

Installed Helm on the control-plane node.

Copied the Cilium `values.yaml` file to the control-plane node with `scp`.

Installed Cilium `1.19.5` with Helm:

```bash
helm repo add cilium https://helm.cilium.io/
helm repo update

helm install cilium cilium/cilium \
  --version 1.19.5 \
  --namespace kube-system \
  --values ~/cilium/values.yaml
```

After installing Cilium:

* control-plane node became `Ready`
* CoreDNS became `Running`
* Cilium agent was `Running`
* one Cilium operator pod was `Running`
* one Cilium operator pod was `Pending` because there is only one node right now
* CoreDNS got Pod IPs from `172.20.0.0/16`

Current technical debt:

* kubeadm init is manual
* Cilium install is manual
* kubeadm defaults were used instead of a config file

Used this to print the command used by worker to join cluster:
 sudo kubeadm token create --print-join-command

Joined both worker nodes with `kubeadm join`.

Validation after joining workers:

* all three nodes are `Ready`
* control-plane: `10.42.1.181`
* worker-1: `10.42.1.34`
* worker-2: `10.42.1.162`
* all nodes are running Kubernetes `v1.36.2`
* all nodes are using `containerd`

Cilium after workers joined:

* one Cilium agent pod is running on each node
* one kube-proxy pod is running on each node
* both Cilium operator pods are now `Running`
* the operator pod that was previously `Pending` could schedule after worker nodes joined

Current cluster state:

* kubeadm control plane is up
* Cilium CNI is installed and working
* all three EC2 nodes have joined the cluster
* system pods are running
* cluster is ready for a small workload scheduling test

Security note:

* kubeadm join tokens should not be pasted into chat, Git, or docs
* exposed or unused join tokens should be deleted with `sudo kubeadm token delete <token-id>`

Created a temporary `lab-test` namespace with a 3-replica HTTP echo Deployment.

The echo Pods scheduled onto the worker nodes and received Cilium Pod IPs:

* `172.20.1.x` on worker-1
* `172.20.2.x` on worker-2

Created a `ClusterIP` Service named `echo`. The Service got a cluster-internal IP and an EndpointSlice with all three echo Pod IPs.

Tested the Service from a temporary curl Pod inside the cluster. `curl http://echo` returned `hello from kubing`, confirming in-cluster DNS, Service routing, and Pod-to-Pod networking.

Deleted one echo Pod manually. Kubernetes created a replacement Pod automatically and returned the Deployment to 3 running replicas.

Decision: workload scheduling, internal Service networking, and basic self-healing behavior are validated.

## 2026-07-09
Today im starting writing some ansible stuff to automate the whole sequence post-terraform deploy that gets the cluster up and running.

Made a inventory file, then did a ping to all my nodes, the command needed some work though, i needed to specify the user ubuntu and i also needed to pass the ssh arg --ssh-common-args='-o StrictHostKeyChecking=accept-new' so that i automaticlly trust first time hosts. 

Also gonna add this to my vars so that its easier in the future:
[all:vars]
ansible_user=ubuntu
ansible_python_interpreter=/usr/bin/python3.12
ansible_ssh_common_args='-o StrictHostKeyChecking=accept-new'

Kubernetes networking. The playbook writes /etc/sysctl.d/k8s.conf with net.ipv4.ip_forward = 1, then runs sysctl --system to apply it.

Validated it with:

ansible nodes -i inventory.ini -m ansible.builtin.command -a "sysctl net.ipv4.ip_forward"

All three nodes returned:

net.ipv4.ip_forward = 1

## 2026-07-10
Got the first real Ansible bootstrap playbook working. It now handles the node prep that I previously did manually after Terraform creates the EC2 instances.

The playbook currently does:

```text id="cu94fl"
enable IPv4 forwarding
set up Docker apt repo
install containerd
generate containerd config
set SystemdCgroup = true
restart and enable containerd
set up Kubernetes v1.36 apt repo
install kubelet, kubeadm, and kubectl
hold the Kubernetes packages
enable/start kubelet
```

This is now the first proper step toward making the cluster rebuildable after `terraform apply`, while still keeping kubeadm init/join and Cilium install manual for now.

Some Ansible lessons from this step:

```text id="ni94sy"
become: true replaces putting sudo everywhere
apt/file/get_url/deb822_repository/systemd modules are better than huge shell blocks
gather_facts is needed here because the playbook uses Ubuntu release and architecture facts
blocks are useful for grouping related tasks like containerd setup and Kubernetes package setup
```

Known cleanup for later: the containerd config generation currently works, but it is not perfectly idempotent because it regenerates `/etc/containerd/config.toml`. Good enough for v0, but should be cleaned up later.

## 2026-07-18 — Kubeadm cluster networking and workload fundamentals

Installed Cilium as the cluster CNI using Helm and a custom `values.yaml`. Confirmed the kubeadm control-plane components, CoreDNS, kube-proxy, Cilium agents, Envoy and Cilium operators were running across the three nodes.

Built a clearer mental model of cluster networking: Pods receive their own IP addresses, and Cilium handles Pod-to-Pod communication across nodes. Cross-node traffic may be encapsulated inside node-to-node traffic, while eBPF allows Cilium to intercept and redirect packets efficiently inside the Linux networking path.

Reviewed the core control-plane roles:

* etcd stores Kubernetes cluster state under `/var/lib/etcd`.
* Controllers continuously reconcile observed status toward the desired spec.
* Nodes without the control-plane role operate as workers.

Worked with Kubernetes workload concepts:

* Jobs run finite work until completion.
* CronJobs create Jobs on a schedule.
* Services provide a stable entry point to changing Pod replicas.
* Liveness probes detect when a container should be restarted.
* Readiness probes determine whether a Pod should receive traffic.
* ConfigMaps and Secrets provide configuration outside the container image.

Deployed Podinfo and tested application failure behavior using its panic and delay endpoints. Inspected environment variables inside a Pod and practiced basic cluster inspection with `kubectl get nodes`, `kubectl get pods` and `kubectl get pods -n kube-system`.

## 2026-07-20
tried to deploy freshrss and postgres to my aws k8s node today. first i had this problem with the db password. i just ended up making a local secret.yaml and applied it on the vm and put it in gitignore so it doesnt go in the repo. gonna fix sealed secrets later when i do gitops for real.

had some stupid k8s problems when doing it:

    forgot to make the freshrss namespace before applying

    api complained because i didnt put quotes around 5432 so it thought it was a number

    got imagepullbackoff on freshrss since 1.28.1 tag is dead i guess. changed to latest.

got the pods to start but the db pvc was just stuck on pending. looked at the events and realized i forgot to install the aws ebs csi driver. so k8s couldnt even talk to aws to make the disk.

decided to just quit for today instead of doing some ugly local disk hack.

todo for next time:

    fix terraform so it gives AmazonEBSCSIDriverPolicy to the node iam role

    add helm in tf so it installs the ebs csi driver automatic

    fix the typos in manifest and put the namespace direct in the yaml so i dont have to do it by hand again

## 2026-07-20 
Today I installed the AWS EBS CSI Driver into my kubeadm Kubernetes cluster using Helm:

- Added the AWS EBS CSI Driver Helm repository
- Installed the driver into the `kube-system` namespace
- Investigated why the EBS CSI node pods were crashing

The issue turned out to be related to AWS Instance Metadata Service (IMDS) connectivity. The EBS CSI driver needs access to IMDS to discover information about the EC2 instance it is running on.

The EC2 instances already had:

```text
HttpPutResponseHopLimit: 2
```
but the pods still could not reach IMDS. The packet path was effectively:

Pod -> Cilium -> Node -> IMDS

which required another hop than expected. Increasing the hop limit to 3 allowed the EBS CSI driver pods to successfully query IMDS and they started running correctly.

I considered rebuilding the cluster with AWS Cloud Controller Manager (CCM), but after investigating the actual issue it was only an IMDS hop limit problem.

Cluster Rebuild / Cilium Setup

I reset the kubeadm cluster while troubleshooting:

sudo kubeadm reset -f
sudo rm -rf /etc/cni/net.d
sudo rm -rf $HOME/.kube/config

After rebuilding:

Reinstalled Cilium CNI
Verified cluster networking
Confirmed the AWS EBS CSI driver was healthy after increasing the IMDS hop limit
PostgreSQL Persistent Storage Issue

While deploying PostgreSQL, I hit a storage initialization issue.

The container failed because the mounted volume was not empty. Linux automatically creates a lost+found directory when formatting filesystems, which caused PostgreSQL initialization to fail.

The solution was not to change the volumeMount path, since it needs to reference the actual mounted partition. Instead, PostgreSQL was configured to use a different data directory through:

PGDATA=/absolute/path/to/subdirectory

This allowed PostgreSQL to initialize successfully while keeping the underlying volume mount unchanged.

## Next Step

The next task is figuring out how to expose FreshRSS securely.

The goal is to make the FreshRSS service reachable externally, but only from my own IP address.

The planned approach is to investigate:

- How to expose the FreshRSS workload outside the cluster
- Whether to use Kubernetes Ingress or another exposure method
- How to restrict access at the AWS VPC/networking layer using IP-based rules
- How Kubernetes Services, Ingress resources, and AWS security controls interact

The target setup is a "public" FreshRSS endpoint from Kubernetes' perspective, but restricted so only my own IP can access it.

# Logbook, 2026-07-21: Exposing FreshRSS to my PC only

**Goal:** get FreshRSS reachable over HTTP from my PC, and only my PC.

## Attempt 1: NGINX Ingress
Planned `hostNetwork` NGINX bound to port 80. Scrapped before installing. Cilium already ships its own Envoy-based ingress, no reason to run two ingress stacks.

## Attempt 2: Cilium Ingress, NodePort mode
```yaml
ingressController:
  enabled: true
  default: true
  loadbalancerMode: shared
  service:
    type: NodePort
    insecureNodePort: 32080
```
`helm upgrade --reuse-values` left the cluster in a broken state. Fixed by nuking Cilium and doing a clean `helm install -f values.yaml` instead.

## Detour: considered AWS LB Controller / CCM
Would mean Terraform: IAM roles for the controller, node instance profiles, subnet tagging. Decided it's overkill for a single-user endpoint, went back to fixing Cilium's own ingress instead.

## Attempt 3: root cause found, working config
Two things were actually broken the whole time:
1. **`kubeProxyReplacement` was never enabled.** Cilium's ingress relies on eBPF/TPROXY interception, which requires Cilium (not kube-proxy) owning service routing.
2. **`loadbalancerMode` was left at the default (`dedicated`)** while trying to use a shared hostNetwork port — so `sharedListenerPort` was never actually applied.

Final `values.yaml`:
```yaml
ipam:
  mode: cluster-pool
  operator:
    clusterPoolIPv4PodCIDRList:
      - 172.20.0.0/16
    clusterPoolIPv4MaskSize: 24
kubeProxyReplacement: true
l7Proxy: true
ingressController:
  enabled: true
  default: true
  loadbalancerMode: shared
  hostNetwork:
    enabled: true
    sharedListenerPort: 32080
envoy:
  enabled: true
```
```
helm upgrade cilium cilium/cilium --namespace kube-system -f values.yaml
kubectl -n kube-system rollout restart deployment/cilium-operator
kubectl -n kube-system rollout restart ds/cilium
```

## Verification
- `cilium status` → kube-proxy replacement active
- `ss -tulpn | grep 32080` on node → Envoy listening on `0.0.0.0:32080`
- `curl http://localhost:32080/` on node → 302 from FreshRSS, `server: envoy`. Full path confirmed working
- Opened EC2 security group: TCP 32080, source = my IP only
- `curl` from my PC → same 302
- Firefox `https://` → `PR_CONNECT_RESET_ERROR` (no TLS configured) — fixed by using `http://` explicitly

## Result
FreshRSS reachable from my PC only, via Cilium's built-in Envoy ingress. No NGINX, no ALB. TLS is a follow-up if I want it later.

## Takeaways
- An `Ingress` object is just declarative config in etcd. Envoy is the actual running process; the Ingress tells it what to do, it doesn't listen for anything itself
- `hostNetwork` binds Envoy straight to the node's real interface, bypassing the pod network
- Cilium's ingress needs kube-proxy replacement specifically because of how it intercepts traffic, not true of bolt-on controllers like nginx

# Logbook, 2026-07-21 (continued)

## Remote Cluster Administration

Today I configured remote administration of my Kubernetes cluster from my laptop.
I exported the Kubernetes client configuration (`kubeconfig`) and certificates from the control plane, configured them locally, and verified that I could successfully interact with the cluster using `kubectl`.
This allows me to manage the cluster directly from my development machine instead of SSHing into the control plane for every administrative task.

## Cluster-Wide DNS Outage

While continuing work on the cluster, I encountered a cluster-wide DNS outage. Pods across the cluster were unable to resolve DNS names, which caused several workloads and infrastructure components to fail.

As part of the initial troubleshooting, I restarted both CoreDNS and the Cilium DaemonSet:

```
kubectl rollout restart deployment coredns -n kube-system
kubectl rollout restart daemonset cilium -n kube-system
```

Although this refreshed the networking components, it did not resolve the underlying issue.

### Root Cause Analysis

The issue was ultimately caused by a conflict between Cilium and kube-proxy.
Both components were managing Kubernetes Service routing at the same time. Since Service routing is responsible for directing traffic to ClusterIP Services, including the CoreDNS Service, this conflict prevented pods from reaching the DNS server.

Without DNS, workloads throughout the cluster were unable to communicate with required services, leading to failures across multiple components, including:

* CoreDNS
* Hubble
* AWS EBS CSI Driver
* Other workloads depending on cluster DNS

## Remote Access Hardening: Tailscale

Replaced the ad hoc SSH tunnel used for remote kubectl access with a permanent Tailscale overlay network, installed on both the node and the laptop. This removes the need to keep a tunnel process alive per session.

Hit a real debugging detour getting there:

* A stale local kubeconfig produced `401 Unauthorized` responses even though the client certificate was not expired.
* Traced with `openssl verify -CAfile ca.crt client.crt`, confirmed the client cert was signed by a CA that no longer matched the cluster's current trusted CA.
* Root cause was a leftover `KUBECONFIG` environment variable pointing at an old file from earlier in the session, silently shadowing the correct, freshly pulled config at the default path. `KUBECONFIG` takes priority over `~/.kube/config` and is scoped per shell, so it stayed wrong in one terminal even after being fixed in another.
* Also hit a near miss editing a decoy file (`~/kube/config` instead of `~/.kube/config`), one missing dot, different directory entirely.
* Fixed by pulling a fresh `admin.conf`, verifying it against the cluster's live CA before editing anything, and standardizing on the default `~/.kube/config` path so no env var is required going forward.

## Completing the kube-proxy Migration

Enabling `kubeProxyReplacement: true` and removing kube-proxy's DaemonSet and ConfigMap surfaced a second, separate failure from the DNS outage above: `cilium-operator` went into `CrashLoopBackOff` and every `cilium-agent` pod reported `Unknown`.

Root cause: both the operator and the agent need to reach the Kubernetes API server as one of their first startup actions, but the API server sits behind a ClusterIP (`10.96.0.1`), and that ClusterIP only resolves once Cilium's own eBPF datapath is actually programmed. With kube-proxy gone, nothing else could translate that address, and Cilium couldn't bootstrap far enough to become the thing doing the translating. A dependency loop that never existed while kube-proxy handled Service routing as an independent process.

Fixed by setting `k8sServiceHost` and `k8sServicePort` in the Helm values, pointing Cilium's agent and operator directly at the control-plane's real IP so they can start without relying on Service routing that doesn't exist yet. Followed by a per-node iptables cleanup (`iptables-save | grep -v KUBE | iptables-restore`) to remove stale rules left behind by kube-proxy.

## Configuration in Git

Checked the working Cilium Helm values into git as `values.yaml` plus a `README.md`. Not GitOps yet, just a documented, reviewable source of truth with a manual drift-check procedure (`helm get values cilium -n kube-system -a | diff` against the committed file).

## Key Takeaways

* Configured secure remote cluster administration using a local kubeconfig, later hardened with Tailscale instead of a manual SSH tunnel.
* Learned how Kubernetes Service routing underpins critical cluster functionality such as DNS, and observed how a Service routing failure cascades into failures across many unrelated-looking components.
* `KUBECONFIG` shadows the default config path and is scoped per shell. A stale value can silently point kubectl at an outdated file for an entire debugging session.
* A client certificate can be valid and unexpired and still fail authentication if it was signed by a CA that no longer matches the cluster's trusted CA. Worth checking with `openssl verify`, not just certificate dates.
* `kubeProxyReplacement: true` is necessary but not sufficient. Fully removing kube-proxy also requires `k8sServiceHost`/`k8sServicePort`, otherwise Cilium's own control components can't reach the API server to bootstrap themselves.
* Started tracking working Helm values in git as a lightweight, pre-GitOps discipline.

## Next

Deploying `kube-prometheus-stack` (Prometheus Operator + Grafana) as the next addition, configuring it independently.

# Logbook, 2026-07-24: Control plane anatomy and the controller pattern

A theory session rather than cluster work. Went through phase 1 of a structured Kubernetes curriculum: control plane internals and the reconciliation model everything else is built on. No changes to the cluster beyond read-only inspection. Cluster is `v1.36.2`, containerd `2.2.6`.

## What I worked through

Traced the full path from `kubectl apply -f deployment.yaml` to a running container, naming every component and handoff. The thing that reframed my whole mental model: `apply` only means validate + persist to etcd + return 201. Nothing is running at that point. Everything after is asynchronous reconciliation, and if the scheduler were down the Deployment would just sit in etcd forever while `apply` still reported success.

Nailed down the request path through the API server before persistence: authentication → authorization → admission → validation → persist. The API server is the only writer to etcd; nothing else in the cluster touches etcd directly. Verified this on my own control plane by grepping the static pod manifests — the scheduler manifest has no etcd connection at all.

Watches vs. polling. Controllers don't poll the API server, they open a long-lived watch and get pushed events. Reconnect after a drop uses `resourceVersion=N` to replay from where you left off, with a full re-LIST fallback if etcd has compacted past that point (`410 Gone`). This is the concrete difference from how Seal works — Seal polls Git on a timer.

Level-triggered vs. edge-triggered, and where Seal sits. A Kubernetes controller acts on *what is* (observed state), not *what changed* (the event), so dropped or duplicate events don't matter — it re-reads reality and reconciles. Seal is level-triggered on its input (reads HEAD, not a queue of commits) but it compares against a last-applied SHA instead of observed reality, so it can't detect drift. If someone `docker stop`s a container or hand-edits an nginx conf, Seal does nothing until the next commit. A controller catches it because it never trusts a record of its own past actions. Noted the hardening path: compare against `docker ps` + file checksums instead of the SHA.

The Deployment → ReplicaSet → Pod chain, verified on FreshRSS. ownerReferences store the lineage as explicit UID pointers on each object (confirmed the Pod's owner UID equals the RS's own UID), so ownership survives a full control plane restart because it lives in the data. The RS selector is the pod template's labels plus `pod-template-hash`, and that hash is a content hash of `spec.template` — same idea as a commit SHA. It's what stops my three FreshRSS ReplicaSets from fighting over the same pods. Rule for what triggers a new RS: does the change require the pods to be rebuilt to take effect? If yes it's in the template → new RS (image, memory limit, env). If no (replicas, revisionHistoryLimit) → same RS.

Scheduler does exactly one thing: picks a feasible, highest-scoring node and writes a Binding (`spec.nodeName`). It never contacts the node or starts anything. Setting `nodeName` is precisely what makes the pod match the target kubelet's watch filter — that's the handoff.

Kubelet as the node-level reconciler. Watches for pods where `spec.nodeName == me`, drives containerd over CRI to pull images and start containers (containerd → runc does the actual work, kubelet never runs a container itself), then reports status back up to the API server. Desired state down, observed state up. It's the only component that writes real pod status, which is why `kubectl get pods` output ultimately comes from the kubelet, indirectly. Also runs probes itself as a continuous per-container loop.

CRDs and operators as the extension mechanism. A CRD teaches the API server a new object type; an operator is just a controller that watches that type and reconciles it, scoped by RBAC on its ServiceAccount and enforced by the API server on every call. Operators compose the built-in machinery — a Postgres operator creates a StatefulSet, and the normal chain takes over — rather than creating pods directly. Inventoried my own cluster's CRDs (`kubectl get crds`): all Cilium. Sorted them into human-authored desired state (`CiliumNetworkPolicy`) vs. operator-populated observed state (`CiliumEndpoint`, `CiliumNode`) — not every CRD is a thing you write.

Static pods and the bootstrap problem. The control plane (apiserver, etcd, scheduler, controller-manager) runs as static pods the kubelet reads straight off disk from `/etc/kubernetes/manifests/`, with no API server or scheduler involved — which is the only way to resolve the chicken-and-egg of the API server needing to already be running. kubeadm *wrote* those manifests once at bootstrap; the kubelet *runs and restarts* them forever after. The kubelet is both the last component in the apply narrative and the first one at boot.

## Key Takeaways

* `apply` = accepted intent, persisted to etcd. Not running. Everything after is async reconciliation.
* Nothing but the API server touches etcd. Every other component talks only to the API server.
* Controllers are level-triggered: they act on observed state, not on the event, which is why the watch stream can be treated as unreliable. This is the specific thing Seal's SHA-comparison design gets wrong for drift.
* ownerReferences are UID pointers stored on the objects, so the DAG survives a control plane restart.
* The scheduler only writes a Binding. The kubelet only reconciles its own node's pods and reports status up. Each component owns one narrow slice.
* An operator is a controller for a custom type, bounded by RBAC, that composes built-in objects rather than bypassing them.
* The control plane node is tainted `NoSchedule` (keeps workloads off) but still runs a kubelet, because static pods bypass the scheduler entirely.

## Next

Phase 2 of the curriculum. Also worth confirming on the cluster: whether `prometheus-operator`'s CRDs (`servicemonitors` etc.) are actually installed, since the kube-prometheus-stack is only partially deployed — `kubectl get servicemonitors` erroring would explain gaps in the monitoring setup.

## 2026-07-25 / 26 — Phase 2: Cilium networking

Worked through Kubernetes networking with Cilium as the concrete
implementation. Confirmed the cluster runs tunnel mode over VXLAN
(port 8472) with kube-proxy replacement, both verified from live
config rather than assumed.

Covered: what the CNI spec actually contracts for vs. what Cilium
adds; encapsulation and its MTU cost; the pod CIDR / service CIDR
split; ClusterIP translation at the socket via eBPF and why no
reverse translation is needed; NodePort and why type=LoadBalancer
stays <pending> without a cloud controller; cluster DNS, search
domains and the ndots:5 cost; NetworkPolicy semantics; ingress.

Experiments on the live cluster:
- Killed the Cilium agent under load. Traffic kept flowing — eBPF
  programs and maps are kernel state, not agent state. New pods
  couldn't be scheduled at all (node tainted NotReady).
- Measured the ndots cost in Hubble: one github.com lookup produced
  five DNS queries, four of them guaranteed NXDOMAIN.
- Wrote a NetworkPolicy restricting Postgres ingress to FreshRSS,
  predicted four outcomes, verified all four. Proved enforcement
  runs on label-derived identity by giving a netshoot pod the
  FreshRSS label and watching it get through.

Real incident, unplanned: FreshRSS wouldn't start. Traced it from
a failed EBS volume attach → CSI driver DNS timeouts → ~50% of DNS
queries failing → one CoreDNS replica unreachable → the control
plane node advertising its Tailscale address instead of its VPC
address. Two independent interface heuristics had both picked
tailscale0 — the kubelet's node IP and Cilium's device detection.
Fixed both (--node-ip in /etc/default/kubelet, devices='{ens+}'
via Helm). Also corrected MTU 1280 → 9001 on that node.

# 2026-07-28 - csi, storage, moved postgres to statefulset

cluster: kubeadm on ec2, 3 nodes, single az (eun1-az1), cilium
driver: aws-ebs-csi-driver v1.62.0

## what i did

went through the whole storage layer. csi architecture, pv/pvc/storageclass, dynamic provisioning, the az trap, access modes, reclaim policies, node failure, statefulsets. then audited my own postgres and migrated it.

## what the audit found

**postgres was a deployment with rollingupdate on an rwo volume.** thats a deadlock waiting for my next apply that touches the pod spec. new pod cant attach while the old one holds the volume, deployment wont kill the old one until the new one is ready. never fired because the pod had only ever been recreated, never rolled.

**two orphaned ebs volumes.** retain kept the pvs from two failed setup attempts on 07-20, 17:39 and 18:02, the 18:10 one is the real one. both released in k8s, available in ec2, 5gib each, just billing. nothing in the cluster tells you. and deleting the pv wouldnt have deleted the volume, would just have lost the volume id.

**single az confirmed from the aws side.** everything in eun1-az1. so waitforfirstconsumer has never actually done anything for me. it starts mattering when i add a node in another az.

## the migration

did the full static pv reconnection instead of just letting it make a new volume, because thats the procedure you actually need on data you cant lose.

1. wrote down the handle first: pvc-65109b10-e472-447c-b4f3-feefc4d38ce4 -> vol-014e28c1ea9d62ddf (5gi)
2. scaled deployment to 0, waited for the volumeattachment to disappear, not just the pod
3. deleted the pvc, patched claimref to null so the pv went available
4. pre-created a pvc named data-postgres-0 (what the volumeclaimtemplate generates) with volumename pinned to the pv
5. wrote the statefulset with a matching volumeclaimtemplate, put the pvc above it in the manifest so apply order cant race
6. applied

pod came up as postgres-0, running in 13s. data-postgres-0 bound to pvc-65109b10, not a new pv. data intact.

## things that wouldve silently broken it

all three look like data loss and arent:

- dropping PGDATA=/var/lib/postgresql/data/pgdata. postgres finds the mount root instead of the data dir and runs initdb into a fresh cluster next to the real one. everything comes up healthy, no feeds.
- changing the pod label off app.kubernetes.io/name: postgres. the service selects on it so freshrss loses its backend. thats dns not data.
- pvc name mismatch. adoption is pure string matching so it just provisions a new empty volume and doesnt error.

## gaps

- **no backups.** retain covers accidental pvc deletion. does nothing for a bad migration or a dropped table which is what actually happens. pg_dump cronjob writing off cluster, ~20 min of work, should be next.
- **no snapshots.** csi-snapshotter isnt installed so the volumesnapshot crds wont work here. lower prio than the dump, and a snapshot isnt a backup anyway, same account same region.
- **no cloud controller manager.** nothing watches ec2 and reports instance state back, so on node failure the ~6 min force detach is the fast path and clearing it early is manual, ie me.

## next

phase 4, prometheus. applies this phases storage stuff to its own retention config.

# Logbook, 2026-07-28, Phase 4: Monitoring

Deployed kube-prometheus-stack, fixed control-plane scrape failures, added Postgres monitoring.

---

## Concepts

**Prometheus pulls, it doesn't receive.** It sends HTTP GETs to `/metrics` endpoints on a schedule. Nothing pushes to it. Metrics live in the process that produced them and travel by plain HTTP.

**Two ways a thing exposes metrics:**
- *Instrumented*: the app serves `/metrics` itself via a Prometheus client library. Cilium, kube-apiserver, controller-manager.
- *Exporter*: a separate process translating for something that doesn't speak Prometheus. `postgres_exporter` connects to Postgres as a normal SQL client, queries the stats views, serves the results as metrics.

**Service discovery.** Pod IPs aren't stable, so Prometheus can't hold a static address list. It watches the API server for EndpointSlices, which are the live list of pod IPs behind a Service, and scrapes each pod directly. It does *not* scrape the Service's ClusterIP, because that load-balances and you'd get one pod at random per scrape instead of all of them separately.

**ServiceMonitor to scrape, the full pipeline:**
1. ServiceMonitor (a CRD) declares: these Services, by label, this named port, this interval
2. Prometheus Operator watches the API server for ServiceMonitors
3. On change, operator regenerates Prometheus's config file and triggers a reload
4. Prometheus resolves that config into concrete addresses via EndpointSlice discovery
5. Prometheus GETs each address on the scrape interval

**Two independent watches, and they fail differently:**
- The *operator* watches ServiceMonitors and builds config. Broken here means the target pool is absent entirely.
- *Prometheus* watches Services and EndpointSlices to resolve addresses. Broken here means the pool exists but is empty, or targets are DOWN.

Scaling a Deployment doesn't touch the operator at all. The config already says "endpointslices matching X", only the resolution changes.

**`up`** is a metric Prometheus synthesises per target: 1 if the scrape succeeded, 0 if not. Health alerts are built on it, which means a failed scrape makes a component look dead even when it's fine.

**Binding.** A listening socket has an address as well as a port. `127.0.0.1` means loopback only, and loopback is *per network namespace*, so a pod's localhost is its own, not the node's. `0.0.0.0` means all interfaces.

**Refused vs timed out**, worth internalising:
- *connection refused*: packet arrived, nothing listening on that interface and port, kernel rejected it
- *connection timed out*: packet vanished. Dropped by NetworkPolicy, or a ClusterIP with no backends

---

## What I did

### Installed the stack

```bash
helm install kps prometheus-community/kube-prometheus-stack \
  --version 87.21.0 \
  --namespace monitoring --create-namespace \
  -f values.yaml -f values-secrets.yaml
```

Chart 87.21.0, appVersion v0.92.1, which is the **operator** version, not Prometheus. Prometheus's own version is set separately by an image tag.

### Alertmanager: the `null` receiver

Supplied my own `alertmanager.config` with a Discord receiver. Broke the config, because:

**Helm merge rules: maps merge key by key, lists replace wholesale.**

- `receivers` is a list, so mine replaced the chart's, deleting the `null` receiver
- `route` is a map, so it merged, and the chart's `routes` sub-route survived, still pointing at `null`
- Result: a route referencing a receiver that no longer exists, so Alertmanager rejects the config

Fix: include `- name: 'null'` in my own receivers list. **If you override a list in Helm values, you own the entire list.**

`null` is a receiver with no delivery config, a black hole. It exists to swallow **Watchdog**, an alert designed to fire permanently as a heartbeat. The intended use is routing it to an external dead-man's-switch service so a dead alerting pipeline shows up as "the heartbeat stopped" rather than as silence.

### Control-plane targets: connection refused

etcd, kube-scheduler, kube-controller-manager all DOWN with connection refused. kubeadm binds their metrics listeners to `127.0.0.1` by default, so they're unreachable from the pod network. The etcd one also fired a false `etcdInsufficientMembers` alert, because the rule counts `up{job=~".*etcd.*"} == 1` and reads a failed scrape as a dead member.

Fixed in `/etc/kubernetes/manifests/`:
- `kube-controller-manager.yaml`: `--bind-address=0.0.0.0`
- `kube-scheduler.yaml`: `--bind-address=0.0.0.0`
- `etcd.yaml`: `--listen-metrics-urls=http://0.0.0.0:2381` (**only** the metrics URL, client and peer URLs left alone)

These are **static pods**. Kubelet watches that directory and restarts the pod on file change, so saving the file *is* the deploy. Back the files up outside that directory first, because a typo takes the component down. `kubectl` hung for roughly 30 seconds while etcd restarted, which is expected: no etcd, no API server reads.

Verified at the socket level rather than trusting the UI:
```bash
sudo ss -tlnp | grep -E '10257|10259|2381'   # want *: not 127.0.0.1:
```

⚠️ **These edits don't survive `kubeadm upgrade`.** It regenerates static pod manifests from the `kubeadm-config` ConfigMap in `kube-system`. For durability, put the args under `controllerManager.extraArgs`, `scheduler.extraArgs`, and `etcd.local.extraArgs` there.

### kube-proxy: empty target pool

`0/0 up`, a different failure. Nothing DOWN because nothing was discovered. Cilium runs in kube-proxy-replacement mode so the DaemonSet doesn't exist, and the chart ships the ServiceMonitor regardless. Set `kubeProxy: enabled: false`.

### Postgres exporter

Installed `prometheus-postgres-exporter` 8.2.0 into `freshrss`.

Values that mattered:
- `config.datasource.host` and `user` are plain strings. `passwordSecret: {name, key}` points at the existing `db-secret`. The chart offers several alternatives for the same value (`password`, `passwordFile`, `passwordSecret`), so fill exactly one.
- `serviceMonitor.enabled: true`
- `serviceMonitor.labels.release: kps`, **the important one**

**The selector gotcha:** my Prometheus has `serviceMonitorSelector: matchLabels: {release: kps}`. Any ServiceMonitor without that label is invisible. No error appears anywhere, the target just never shows up. (`serviceMonitorNamespaceSelector: {}` means all namespaces, so cross-namespace was never the issue.)

### NetworkPolicy blocking the exporter

Target green but scrapes timing out. Exporter logs showed `dial tcp 10.111.238.133:5432: connect: connection timed out`, so DNS resolved but TCP never connected.

Cause: an existing NetworkPolicy on Postgres allowing ingress *only* from `app: freshrss`. **Once a policy selects a pod, that pod is default-deny for the covered direction.** FreshRSS kept working because it matches, and the exporter was dropped silently. Namespaces are not a network boundary, so being in the same namespace bought nothing: NetworkPolicy matches on labels.

Fix, adding a second `podSelector` as a separate list item under `from`. Separate items mean OR, nested under one item would mean AND.

```yaml
  ingress:
    - from:
      - podSelector:
          matchLabels:
            app: freshrss
      - podSelector:
          matchLabels:
            app.kubernetes.io/instance: pgexporter
      ports:
      - protocol: TCP
        port: 5432
```

**Two different health signals, one per hop:**
- `up`: Prometheus reached the exporter
- `pg_up`: the exporter reached Postgres

A green target with `pg_up == 0` means the exporter is fine and the database isn't. Each layer's health metric only covers its own hop.

---

## Commands worth keeping

```bash
# what's listening, and on which interface
sudo ss -tlnp | grep <port>

# does my Prometheus require a label on ServiceMonitors?
kubectl get prometheus -n monitoring -o yaml | grep -A5 serviceMonitorSelector

# the live pod list behind a Service
kubectl get endpointslices -n <ns>

# reach a UI without ingress (bypasses Services and NetworkPolicy entirely)
kubectl port-forward -n monitoring svc/kps-kube-prometheus-stack-prometheus 9090
```

Prometheus UI: **Status → Targets**, **Status → Configuration** (generated config), **Status → Service Discovery** (discovered before filtering).

---

## Open items

- [ ] `retentionSize` alongside `retention`, since a time bound alone won't stop the PVC filling first
- [ ] NetworkPolicy change is applied to the cluster, but is it committed to the repo?
- [ ] `kubeProxy: enabled: false` needs a `helm upgrade` to take effect
- [ ] PromQL: `rate()`, `sum by`, `histogram_quantile`, the real remaining gap
- [ ] One PrometheusRule I wrote myself, e.g. `pg_up == 0`, or connections approaching `max_connections`
- [ ] A Grafana panel I'd actually open
- [ ] Record the static-pod arg change in `kubeadm-config` so it survives upgrades

## 2026-07-30
- add retentionSize: 1600MB to prometheus spec, previously i just had the 7 day retention period but that doesnt limit how MUCH data can be stored in that interval
- then upgrade my helm install of the monitoring stack
- open port forward to grafana
- open coredns dashboard tracking requests and stuff, then run a nslookup loop pod in the cluseter, the spike is visible in grafana but also kindof overwhelmed the node that was running the loop.
- make 6 dashboards:
# 1. Postgres reachable (Stat)

pg_up

# 2. Connections per database (Time series)

pg_stat_database_numbackends

# 3. Connection headroom (Gauge, unit: percent 0.0-1.0)

sum(pg_stat_database_numbackends) / on() pg_settings_max_connections

# 4. PVC fill (Bar gauge, unit: percent 0.0-1.0)

kubelet_volume_stats_used_bytes / kubelet_volume_stats_capacity_bytes

# 5. Restarts in the last 15min (Table)

changes(kube_pod_container_status_restarts_total[15m]) > 1

# 6. Pods not Running (Stat)

sum by (namespace) (kube_pod_status_phase{phase!="Running"})


export to json, remove id, make configmap this way:
kubectl create configmap cluster-overview-dashboard \
  --from-file=cluster-overview.json=cluster-overview.json \
  --namespace monitoring \
  --dry-run=client -o yaml > dashboard-cluster-overview.yaml

then add this to metadata block: 
metadata:
  name: cluster-overview-dashboard
  namespace: monitoring
  labels:
    grafana_dashboard: "1"

then i do a rollout restart on the grafana deployment, dashboard is still there, meaning its reproducible

also make this alert:
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: postgres-rules
  namespace: monitoring
  labels:
    release: kps
spec:
  groups:
    - name: postgres
      rules:
        - alert: PostgresDown
          expr: pg_up == 0
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "Postgres unreachable"
            description: "The exporter has failed to connect for 5 minutes."


## 2026-07-30
- Do a cluster wide inventory

## Deployed

| Release | Namespace | Chart |
|---|---|---|
| `cilium` | kube-system | cilium 1.19.6, rev 20 |
| `aws-ebs-csi-driver` | kube-system | 2.62.0 |
| `kps` | monitoring | kube-prometheus-stack 87.21.0, rev 3 |
| `pgexporter` | freshrss | prometheus-postgres-exporter 8.2.0 |

Plus twelve hand-written objects: freshrss (Namespace, Deployment, Service,
Ingress, PVC, StatefulSet/postgres, Service/postgres, NetworkPolicy, db-secret),
monitoring (Namespace, dashboard ConfigMap, PrometheusRule/postgres-rules), and
StorageClass/ebs-gp3-retain.

Flux adopts Helm releases by name, so the HelmRelease must be `kps`, not
`kube-prometheus-stack`, or it installs a second copy.

## Ownership

- **Flux**: the twelve objects, plus EBS driver, kps, pgexporter
- **Ansible**: kubeadm, kubelet, Cilium, the `--bind-address=0.0.0.0` edits in
  `/etc/kubernetes/manifests/`
- **Terraform**: EC2, VPC, IAM, EBS volumes

Cilium is out because Flux runs as pods. A bad Cilium apply kills networking and
takes Flux with it. The EBS driver has no such problem.

Order: Ansible, bootstrap, EBS driver, StorageClass, kps, then apps.

## Secrets

SOPS with age. Encrypt `db-secret` and the contents of `values-secrets.yaml`.
The age key cannot live in Git, so one `kubectl create secret` before every
bootstrap is the rebuild's only manual step. README should say so.

## Loose ends

- `helm get values cilium -n kube-system > cilium/values.yaml` while the cluster
  still exists
- Resolve `cilium/` versus `platform/cilium/`
- etcd metrics probably not exposed, no `--bind-address` flag on etcd
flux bootstrap:
export GITHUB_TOKEN=
export GITHUB_USER=viper6z

flux bootstrap github \
  --owner=$GITHUB_USER \
  --repository=kubing \
  --branch=main \
  --path=clusters/homelab \
  --persona
