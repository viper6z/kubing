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
