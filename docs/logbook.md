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

