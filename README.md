# kubing

A self-managed Kubernetes cluster on AWS, provisioned with Terraform and managed by Flux, running FreshRSS with Postgres, kube-prometheus-stack, and the EBS CSI driver. Secrets are SOPS-encrypted in the repo and decrypted by Flux at reconcile time, so the whole cluster state lives in Git. The goal is full reproducibility from scratch: Ansible for node bootstrap and a CI pipeline to tie it together are next.
