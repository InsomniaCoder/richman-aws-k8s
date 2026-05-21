# Networking

This document covers the full network stack — from VPC topology to in-cluster policy — and explains the reasoning behind each layer.

---

## VPC topology

```
Primary CIDR:    10.0.0.0/16     (nodes, load balancers, NAT)
Secondary CIDR:  100.64.0.0/10   (pods only — RFC 6598 address space)

VPC
│
├── AZ-a (eu-west-1a)
│   ├── Public  10.0.0.0/24        NLB, NAT Gateway — no nodes run here
│   ├── Private 10.0.10.0/24       EKS system nodes + Karpenter workload nodes
│   └── Pod     100.64.0.0/12      Pod IPs only (VPC CNI ENIConfig)
│
├── AZ-b (eu-west-1b)
│   ├── Public  10.0.1.0/24
│   ├── Private 10.0.11.0/24
│   └── Pod     100.80.0.0/12
│
└── AZ-c (eu-west-1c)
    ├── Public  10.0.2.0/24
    ├── Private 10.0.12.0/24
    └── Pod     100.96.0.0/12
```

### Why three subnet tiers

**Public** subnets hold only load balancer endpoints and NAT Gateways. No EC2 nodes are placed here — all compute lives in private subnets, meaning nodes have no direct internet-facing exposure.

**Private** subnets hold nodes. Egress goes through the NAT Gateway. Inbound traffic arrives only through the load balancer tier (NLB → Traefik). Nodes are not reachable from the internet directly.

**Pod** subnets live in a separate secondary CIDR block (`100.64.0.0/10`, RFC 6598 address space) attached to the VPC. Each AZ gets a /12 (1,048,576 IPs). This cleanly separates pod and node address space — no risk of pod IPs colliding with node IPs or with corporate on-premises ranges that typically use `10.x.x.x`.

Using RFC 6598 space is the recommended EKS pattern for large clusters. `100.64.0.0/10` is not routable on the public internet and is not commonly used in corporate networks, making it safe for VPC secondary CIDRs.

**Multi-cluster note:** In a real environment with multiple clusters sharing the same VPC (or the same AWS account), allocate a sub-range of the /10 per cluster to avoid ENIConfig subnet overlap. For example: cluster-1 uses `100.64.0.0/12`, cluster-2 uses `100.80.0.0/12`, cluster-3 uses `100.96.0.0/12`. This is controlled by the `pod_cidr` variable in the VPC module. Each cluster's Terragrunt `env.hcl` sets a different `pod_cidr`.

### NAT Gateways

One per AZ. Pods in AZ-a exit through the AZ-a NAT Gateway — no cross-AZ hops for outbound traffic. At meaningful scale, same-AZ egress savings outweigh the cost of three NAT Gateways vs one.

Set `single_nat_gateway = true` in `env.hcl` to use one shared NAT Gateway for dev/cost-sensitive environments. This introduces a cross-AZ dependency but cuts NAT cost by two-thirds.

### Pod subnet ENIConfig

Each pod subnet is tagged `topology.kubernetes.io/zone=<az>`. The VPC CNI addon reads `ENI_CONFIG_LABEL_DEF=topology.kubernetes.io/zone` from its configuration and selects the ENIConfig matching the node's AZ label automatically. No manual mapping is needed when adding nodes to new AZs.

---

## VPC CNI configuration

```
ENABLE_PREFIX_DELEGATION           = true
AWS_VPC_K8S_CNI_CUSTOM_NETWORK_CFG = true
ENI_CONFIG_LABEL_DEF               = topology.kubernetes.io/zone
NETWORK_POLICY_ENFORCING_MODE      = standard
```

**Prefix delegation** — instead of allocating one IP per ENI slot, the CNI allocates /28 blocks (16 IPs) per slot. An `m6i.xlarge` with 3 ENIs × 10 slots would normally hold 30 pods; with prefix delegation it holds 30 × 16 = 480 pod IPs. The /12 pod subnets (1M+ IPs each) make exhaustion effectively impossible even at this scale.

**Custom network mode** — pod IPs come from ENIConfigs pointing at pod subnets rather than the node's primary subnet. Required to use the dedicated pod subnets.

**NetworkPolicy enforcement** — `standard` mode loads an eBPF program per node that enforces `NetworkPolicy` objects at the kernel level. No separate CNI plugin (Calico, Cilium) is needed. The enforcement is genuine — packets are dropped before they reach the pod's network stack, not just at an application layer.

---

## VPC endpoints

Interface and Gateway endpoints keep AWS API traffic off the public internet and avoid NAT Gateway charges for those paths.

| Endpoint | Type | Reason |
|---|---|---|
| S3 | Gateway (free) | ECR image layer pulls, Velero backups, Terraform state |
| ECR API (`ecr.api`) | Interface | Image manifest lookups |
| ECR Docker (`ecr.dkr`) | Interface | Image layer downloads |
| Secrets Manager | Interface | ESO secret fetches |
| SSM | Interface | Session Manager access, SSM Parameter Store reads |
| STS | Interface | Pod Identity token exchanges (happens on every pod start) |
| EC2 | Interface | Karpenter instance provisioning and Fleet API calls |

Interface endpoints are deployed across all 3 AZs for HA. Each costs ~$7/mo per AZ (~$63/mo total for 3 AZs × 3 endpoints). Controlled by `create_vpc_endpoints = false` in `env.hcl` to disable for dev environments where cost matters more than private routing.

---

## External traffic path

```
Internet
  │
  ▼
Route 53 A record  →  NLB (internet-facing, public subnet)
                            │
                            │  Port 80 / 443
                            ▼
                      Traefik (public)   [system nodes, traefik namespace]
                            │
                            │  Routed by IngressRoute / Ingress
                            ▼
                      Workload pod       [private/pod subnet, any AZ]
```

The NLB is provisioned by AWS Load Balancer Controller via the `service.beta.kubernetes.io/aws-load-balancer-*` annotations on Traefik's Service. It operates at L4 — TLS passthrough to Traefik, which terminates TLS at L7.

ExternalDNS watches Ingress and IngressRoute resources and creates/updates Route 53 A records automatically. `txtOwnerId` is set to the cluster name — without this, a second cluster would delete this cluster's DNS records when it reconciles.

---

## Internal traffic path

```
VPC-internal client (another service, CI/CD, admin tool)
  │
  ▼
NLB (internal, private subnet)
  │
  ▼
Traefik (internal)   [system nodes, traefik-internal namespace]
  │
  ▼
Workload pod
```

Internal Traefik uses `ingressClassName: traefik-internal`. Services that must not be internet-facing (admin UIs, internal APIs, inter-service traffic) use this class. The NLB scheme is `internal` — it has no public IP and is only reachable from within the VPC or connected networks (VPN, Direct Connect).

---

## In-cluster topology-aware routing

Services in workload namespaces get `service.kubernetes.io/topology-mode: "Auto"` injected by a Kyverno mutation policy. The EndpointSlice controller adds topology hints to endpoints, and kube-proxy preferentially routes traffic to endpoints in the same AZ as the calling pod.

**Effect:** pod-to-service calls stay within a single AZ when endpoints are available there, avoiding ~$0.01/GB cross-AZ data transfer charges.

**Failure mode:** if same-AZ endpoints are unhealthy or the ratio would be unbalanced, routing falls back to all endpoints normally. This is a cost optimisation, not a hard constraint.

To opt a specific Service out, label it:
```yaml
metadata:
  labels:
    service.kubernetes.io/topology-mode: "disabled"
```

---

## Security groups

Three groups. Membership, not CIDR ranges, is used for inter-component rules.

### `sg-control-plane`
Attached to the EKS control plane ENIs.

| Direction | Port | Source | Purpose |
|---|---|---|---|
| Inbound | 443 | `sg-nodes` | kubelets and pods calling the API server |
| Outbound | 10250 | `sg-nodes` | API server → kubelet (exec, logs, metrics) |

### `sg-nodes`
Attached to all EC2 nodes (system node group + Karpenter-provisioned nodes).

| Direction | Port | Source/Dest | Purpose |
|---|---|---|---|
| Inbound | all | `sg-nodes` | Node-to-node (overlay traffic, health checks) |
| Inbound | 443 | `sg-nlb` | NLB health probe |
| Inbound | all node ports | `sg-nlb` | NLB target traffic |
| Outbound | 443 | `sg-control-plane` | kubelet → API server |
| Outbound | all | `0.0.0.0/0` | General egress (via NAT / VPC endpoints) |

### `sg-nlb`
Attached to the NLB.

| Direction | Port | Source | Purpose |
|---|---|---|---|
| Inbound | 80, 443 | `0.0.0.0/0` | HTTP/HTTPS from internet |
| Outbound | all | `sg-nodes` | Health probes + forwarded traffic |

---

## NetworkPolicy model

VPC CNI native enforcement is active (`NETWORK_POLICY_ENFORCING_MODE=standard`). All `NetworkPolicy` objects produce real eBPF kernel rules — not advisory annotations.

### Default policies (auto-generated per namespace)

Kyverno generates six `NetworkPolicy` objects when any workload namespace is created. System namespaces (kube-system, argocd, monitoring, karpenter, kyverno, cert-manager, external-secrets, external-dns, traefik, traefik-internal, velero, cloud-custodian) are excluded — they manage their own access patterns.

| Policy | Type | What it does |
|---|---|---|
| `default-deny-ingress` | Ingress | Blocks all cross-namespace ingress — baseline tenant isolation |
| `allow-ingress-from-traefik` | Ingress | Allows HTTP/HTTPS routing from the public ingress controller |
| `allow-ingress-from-traefik-internal` | Ingress | Allows routing from the internal ingress controller |
| `allow-ingress-from-monitoring` | Ingress | Allows Prometheus to scrape metrics endpoints |
| `allow-ingress-same-namespace` | Ingress | Allows pod-to-pod communication within the same namespace |
| `deny-egress-to-kubelet` | Egress | Blocks TCP 10250 — pods must not reach node kubelet APIs |

All policies use `synchronize: true`. If one is manually deleted, Kyverno recreates it immediately.

### Why ingress-only isolation (except kubelet)

Restricting egress in a default policy is operationally expensive — every workload that calls an external API, database, or AWS service would need an explicit allowlist rule. Ingress restriction is sufficient for tenant isolation: a workload in namespace A cannot receive unsolicited connections from namespace B, but can still make outbound calls freely.

The kubelet egress block is a specific exception because TCP 10250 exposes exec and log APIs — a compromised pod reaching a kubelet can read other pods' logs or probe node-level metadata. This is blocked by default without restricting general outbound traffic.

### How the kubelet egress rule works

Kubernetes `NetworkPolicy` is an allowlist — adding `policyTypes: [Egress]` blocks all egress except what is listed. To block only port 10250, the policy explicitly allows all other TCP (ports 1–10249 and 10251–65535) and all UDP. The result is a precise block of only the kubelet port without affecting normal workload egress.

### Adding a workload-specific NetworkPolicy

To allow traffic from a specific namespace (e.g., a calling service in `payments` namespace):

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-from-payments
  namespace: orders
spec:
  podSelector: {}
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: payments
  policyTypes:
    - Ingress
```

The auto-generated `default-deny-ingress` does not block this — adding an allow rule on top of it opens the specific path.

---

## DNS

### CoreDNS

Managed EKS addon. Handles all in-cluster DNS resolution: Service names, headless service pod records, and external lookups (forwarded to VPC DNS resolver at `169.254.169.253`).

### NodeLocal DNSCache

DaemonSet running on every node. Intercepts DNS queries before they leave the node, caches responses, and eliminates the conntrack race condition that causes `SERVFAIL` errors under high DNS query rates (common beyond ~50 pods/node).

**What the race condition is:** Under load, UDP DNS queries from multiple pods can land in the conntrack table simultaneously. If a response arrives while another entry is being written, the conntrack lookup fails and the query is dropped. NodeLocal DNSCache avoids this by using TCP (not UDP) to talk to CoreDNS upstream, where connections are stateful and the race cannot occur.

**How to verify NodeLocal DNSCache is active on a node:**
```bash
kubectl exec -it <pod> -- cat /etc/resolv.conf
# nameserver should be 169.254.20.10 (NodeLocal DNSCache link-local address)
# not 172.20.0.10 (CoreDNS ClusterIP)
```

### ExternalDNS

Watches `Ingress` and `IngressRoute` resources and reconciles Route 53 A records. Configuration points:

- `policy: upsert-only` (default) — creates records but does not delete them; safe starting point
- `policy: sync` — creates AND deletes records when Ingresses are removed; set this once `txtOwnerId` is confirmed correct
- `txtOwnerId: <cluster_name>` — critical for multi-cluster setups; ExternalDNS writes this value into TXT ownership records and only deletes records it owns
- `domainFilters` — scoped to one hosted zone; prevents accidental changes to records in other zones

---

## Network observability — Retina

Retina (Microsoft) runs as a DaemonSet on every node, loading eBPF probes that capture:

- **Packet drops** — with drop reason (policy, conntrack, routing)
- **TCP retransmits** — per pod, indicates congestion or flapping connections
- **DNS errors** — NXDOMAIN rate, timeout rate per pod
- **Latency** — p50/p95/p99 for TCP connections per pod pair
- **Connection counts** — active connections per pod

Metrics are exposed on port 10093 and scraped by Prometheus via ServiceMonitor. Grafana dashboards surface per-pod and per-node views.

**Why this matters alongside Prometheus:** Prometheus application metrics show what the application observes (request latency, error rates). Retina shows what the network is doing underneath — whether slow requests correlate with TCP retransmits, whether DNS timeouts are causing connection delays, or whether a NetworkPolicy is silently dropping packets.

---

## Cert-manager and TLS

cert-manager handles TLS certificate lifecycle. It is installed in wave 2 alongside the rest of platform-networking because AWS LBC, Traefik, and ESO all depend on cert-manager for their webhook TLS certificates.

**`crds.keep: true`** — without this flag, `helm uninstall` deletes all `Certificate`, `ClusterIssuer`, and `CertificateRequest` objects in the cluster. Once CRDs are deleted, re-installing cert-manager does not restore the certificate objects. Set this flag from day one.

**DNS-01 ACME challenge** — cert-manager uses Route 53 DNS-01 validation for Let's Encrypt certificates. This works for wildcard certificates and for clusters without public HTTP access. ExternalDNS and cert-manager use the same hosted zone.

**`maxConcurrentChallenges: 15`** — limits simultaneous ACME challenges to avoid Let's Encrypt rate limits (50 certificates per registered domain per week).

---

## Recommended operator checklist

When deploying a new workload:

- [ ] Use `ingressClassName: traefik` for internet-facing routes, `traefik-internal` for VPC-internal routes
- [ ] Do not set `hostNetwork: true` or `hostPID: true` — Kyverno will deny the pod
- [ ] Verify your `Service` has `topology-mode: Auto` (injected automatically, but check if you see cross-AZ charges)
- [ ] If your service needs to receive traffic from a specific other namespace, add an explicit `NetworkPolicy` allow rule — the generated default-deny will block it otherwise
- [ ] If you need to reach the kubelet (e.g. a custom metrics agent), add a namespace exclusion in the Kyverno policy `default-network-policies` — workload namespaces cannot reach port 10250 by default
- [ ] Check Retina dashboards for elevated drop rates or DNS timeouts after deploying — these are invisible in application-level metrics
