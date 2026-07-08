## Kubernetes node preparation checklist

Source: Kubernetes kubeadm installation docs.

For each node:
- Confirm Ubuntu version / kernel baseline.
  
- Verify hostname, MAC address, and product_uuid are unique.
- Check network adapter and default route.
- Confirm private node-to-node networking is allowed by the AWS security group.
- Disable or otherwise handle swap.
- Install and configure containerd as the container runtime.
- Install kubeadm, kubelet, and kubectl.
- Pin/hold Kubernetes package versions.
- Validate kubelet and container runtime state before running kubeadm.
