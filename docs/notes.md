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
