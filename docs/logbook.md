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


