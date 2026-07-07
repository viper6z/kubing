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

Added Docker’s official apt repository on all three nodes and installed containerd.io only, not Docker Engine.

Updated /etc/containerd/config.toml to enable CRI and configure containerd to use the systemd cgroup driver with SystemdCgroup = true. Restarted containerd and verified the service and CRI plugins were active.
