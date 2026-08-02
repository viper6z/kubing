# kubing

This is my self managed kubernetes cluster running on AWS EC2.

Everything that is running on the cluster apart from the control plane layer and Cilium is declared in this repo and managed/reconciled by Flux. That includes FreshRSS, Postgres, the EBS CSI, the monitoring stack (kube-prometheus-stack), as well as the cluster secrets which are SOPS encrypted.

## Architecture

The cluster runs on three EC2 nodes and is bootstrapped with kubeadm, not a managed Kubernetes service. Cilium is running in kube-proxy replacement mode on the cluster, meaning that the Cilium agent loads eBPF programs into the kernel that do service load balancing and enforce network policies, replacing kube-proxy entirely. For node to node traffic, Cilium uses VXLAN to encapsulate the frames in UDP datagrams. Since the pod to pod traffic on the pod network (172.20.0.0/16) isn't routable in the VPC, this encapsulation enables pod to pod traffic to be carried between nodes. Inbound traffic, currently restricted to a single admin IP by security group, reaches a node on port 32080, where Envoy (Cilium's ingress proxy, on the host network) is listening. The envoy receives the http request and matches it to its ingress routes, and then makes another request to a real pod ip that sits behind that service. The return traffic goes through the proxy aswell.

Persistent storage is provided by the AWS EBS CSI driver. Workloads request storage through a PVC against the ebs-gp3-retain StorageClass, and the driver provisions an EBS volume in AWS and attaches it to the node where the pod is scheduled. The storageclass runs with volumeBindingMode: WaitForFirstConsumer which means that the pod associated with the PVC has to be scheduled to a node before the persistent volume is created. The storageclass also runs reclaimPolicy: Retain, which means that the Persistent volume will survive PVC deletion.

The cluster is managed remotely by me via Tailscale. The kubeconfig on my local machine is pointed at the control planes tailscale ip. The tailnet address is included in the API server's certificate SAN's.

## GitOps

Flux is structured around Kustomizations in clusters/homelab/ which point at paths located in apps/ or infrastructure/. These paths contain the manifests that Flux uses to reconcile what's running on the cluster. Each Kustomization sets the reconcile interval and, where the path holds SOPS-encrypted secrets, references the Kubernetes Secret containing the age private key used to decrypt at reconcile time, which is what allows secrets to sit encrypted in the repo. The Kustomizations also have dependencies that ensure that the infrastructure/controllers path is reconciled before the infrastructure/configs path, so the CRDs the controller charts ship are present before custom resources of those types are applied. The apps/ paths also depend on the infrastructure/configs path to be reconciled even though they dont necessarily have to in order to follow a clean ordering of platform -> workloads. The HelmReleases were brought under Flux control without downtime by matching the releaseName in the manifest to what was already running in the cluster, and by matching the values in the manifest with what was running in the cluster, that way Flux took over the existing release history and proceeded as an upgrade instead of deploying a new one in parallel.


## Repo layout

ansible/ -> Node preparation up to (not including) kubeadm init

apps/ -> contains manifests for application workloads, referenced by Kustomizations in clusters/

cilium/ -> Helm values for Cilium, installed manually, not Flux-managed (a CNI can't be reconciled by a controller that needs pod networking to exist).

clusters/homelab/ -> Contains all Kustomizations that Flux uses

docs/ -> logbook

infrastructure/ -> Contains the manifests for controllers and custom resources

scripts/ -> Contains scripts to start the cluster and my tmux workspace

terraform/ -> The terraform code that declares the AWS environment that houses the cluster.

terraform/bootstrap/ -> Used for bootstrapping a terraform backend and IAM plumbing for future automated workflows that use OIDC and SSM


## Known limitations

- No backups
- No snapshots
- No cloud-controller-manager
- Nodes are lightweight
- No TLS for public connections

Node-local edits not in Git. Some control plane configuration was made by hand on the nodes and isn't captured anywhere in this repo:

- bind-address=0.0.0.0 on the scheduler and controller-manager, and --listen-metrics-urls on etcd, so Prometheus can scrape them off the pod network rather than localhost. These live in the static pod manifests under /etc/kubernetes/manifests/ and don't survive kubeadm upgrade; the durable fix is extraArgs in the kubeadm-config ConfigMap.

- node-ip in /etc/default/kubelet on the control plane, pinning the VPC address, because the kubelet's interface heuristic otherwise picks the Tailscale interface. Without it, the node advertises a tailnet address and cluster DNS degrades.
