# Architecture

`richman-aws-eks` is a production-grade EKS platform. This document covers every significant design decision and the rationale behind it.

---

## VPC & Networking

### Topology — 3 AZs, 3 subnet tiers

```
Primary CIDR:   10.0.0.0/16    (nodes, load balancers, NAT)
Secondary CIDR: 100.64.0.0/10  (pods only — RFC 6598)

VPC
├── AZ-a
│   ├── Public  10.0.0.0/24      NLB, NAT Gateway — no nodes
│   ├── Private 10.0.10.0/24     System nodes, Karpenter workload nodes
│   └── Pod     100.64.0.0/12    Pod IPs only (VPC CNI ENIConfig)
├── AZ-b
│   ├── Public  10.0.1.0/24
│   ├── Private 10.0.11.0/24
│   └── Pod     100.80.0.0/12
└── AZ-c
    ├── Public  10.0.2.0/24
    ├── Private 10.0.12.0/24
    └── Pod     100.96.0.0/12
```

**Why dedicated pod subnets with RFC 6598 space:** Pod IPs come from a secondary CIDR block (`100.64.0.0/10`) attached to the VPC rather than the primary `10.0.0.0/16`. This cleanly separates pod and node address space and avoids collision with corporate on-premises ranges that typically use `10.x.x.x`. Each AZ gets a /12 (1M+ IPs). Combined with prefix delegation (`ENABLE_PREFIX_DELEGATION=true`), IP exhaustion is effectively impossible. In a multi-cluster account, allocate a different sub-range of the /10 per cluster via the `pod_cidr` variable — e.g. cluster-1: `100.64.0.0/12`, cluster-2: `100.80.0.0/12`.

**Pod subnet ENIConfig:** Each pod subnet is tagged `topology.kubernetes.io/zone=<az>` matching `ENI_CONFIG_LABEL_DEF`. The CNI selects the correct subnet automatically based on the node's AZ label.

**NAT Gateways:** One per AZ (3 total) to avoid cross-AZ data transfer charges on pod egress. Controlled by `single_nat_gateway` variable — set to `true` for dev/cost-sensitive environments.

**EKS API public access:** Scoped to `admin_cidr` variable. AWS hard limit: 40 CIDRs — validated by Terraform.

### VPC Endpoints

| Endpoint | Type | Why |
|---|---|---|
| S3 | Gateway (free) | ECR layer pulls, Velero, Terraform state — stays on AWS backbone |
| ECR API + DKR | Interface | Image pulls without NAT traffic |
| Secrets Manager | Interface | ESO secret fetches stay private |
| SSM | Interface | Session Manager, SSM Parameter Store |
| STS | Interface | Pod Identity token exchanges |
| EC2 | Interface | Karpenter instance provisioning |

Interface endpoints deployed across all 3 AZs for HA. Controlled by `create_vpc_endpoints`.

### Security groups

- `sg-control-plane` — EKS control plane; allows 443 inbound from `sg-nodes`
- `sg-nodes` — all nodes (system + Karpenter); full bidirectional within itself, 443 outbound to control plane
- `sg-nlb` — NLB; allows 80/443 from `0.0.0.0/0`

### NetworkPolicy enforcement

VPC CNI native policy controller (`NETWORK_POLICY_ENFORCING_MODE=standard`) — no separate CNI plugin needed. Kyverno generates four NetworkPolicies on namespace creation (see Policy section).

### Topology-aware routing

Services in workload namespaces get `service.kubernetes.io/topology-mode: "Auto"` via Kyverno mutation. kube-proxy/endpointslice controller preferentially routes traffic to endpoints in the same AZ as the client pod. Falls back to random selection when same-AZ endpoints are unavailable — no failure mode, only cost optimization.

---

## IAM & Pod Identity

### Why Pod Identity over IRSA

- No OIDC provider URL in trust policies
- No per-ServiceAccount annotation
- Same role works across clusters
- `aws_eks_pod_identity_association` — one Terraform resource per service account

**Pod Identity is the only mechanism used in this project.** IRSA is documented in the README for cross-account scenarios where Pod Identity does not reach.

### Account-level roles

| Role | Purpose |
|---|---|
| `eks-cluster-role` | EKS control plane — `AmazonEKSClusterPolicy` |
| `eks-node-role` | All EC2 nodes — `AmazonEKSWorkerNodePolicy`, `AmazonEC2ContainerRegistryReadOnly`, `AmazonSSMManagedInstanceCore` |

Node role carries no application permissions — all AWS access is via Pod Identity.

### Pod Identity associations

| Service Account | Namespace | Permissions |
|---|---|---|
| `karpenter` | `karpenter` | EC2 Fleet, SQS, pricing, SSM, `iam:PassRole` (node role, condition-scoped) |
| `aws-load-balancer-controller` | `kube-system` | ELB full, EC2 describe, WAF |
| `external-dns` | `external-dns` | Route 53 `ChangeResourceRecordSets` (scoped to hosted zone) |
| `external-secrets-sa` | `external-secrets` | Secrets Manager `GetSecretValue`, `DescribeSecret` |
| `ebs-csi-controller-sa` | `kube-system` | EC2 volume lifecycle |
| `velero` | `velero` | S3 read/write (backup bucket), EC2 snapshot |
| `cloud-custodian` | `cloud-custodian` | Account-wide read + tag/remediation |
| `yace` | `monitoring` | CloudWatch `GetMetricData`, `ListMetrics` |
| `noe` | `monitoring` | EC2 describe instances |

---

## EKS Cluster

### Managed addons

| Addon | Notes |
|---|---|
| `vpc-cni` | Prefix delegation + custom networking + NetworkPolicy enforcement |
| `kube-proxy` | Service iptables, AWS-managed lifecycle |
| `coredns` | Managed lifecycle |
| `aws-ebs-csi-driver` | EBS provisioner, `WaitForFirstConsumer` binding for same-AZ volumes |
| `eks-pod-identity-agent` | Tolerates system node taint; handles Pod Identity token exchange on the node |

All addon versions pinned in `live/<env>/cluster/eks/terragrunt.hcl`.

### System node group

Fixed ON_DEMAND managed node group for cluster-critical components (Karpenter, ArgoCD, cert-manager, Kyverno admission webhook, VPA admission controller, OTEL Operator):

- **Instance:** `m6i.xlarge` primary, same-spec fallbacks via instance-type filter
- **Sizing:** `min=2, desired=2, max=4`, ON_DEMAND, multi-AZ
- **Taint:** `system-node=true:NoSchedule`
- **Label:** `node.kubernetes.io/role=system`

System nodes are not autoscaled — scaling is a deliberate Terraform change.

### Authentication

`authentication_mode = "API_AND_CONFIG_MAP"`. Admin access via EKS access entries (not `aws-auth` ConfigMap). No static kubeconfig credentials — `kubectl` requires a valid AWS session.

---

## Node Autoscaling — Karpenter

Karpenter runs on system nodes (toleration + nodeAffinity for `system-node=true`), provisions workload nodes via EC2 Fleet.

### NodePool design with NodeOverlay pattern

Each architecture has two pools: **preferred** (newest gen, weight 100) and **overlay** (older gen fallback, weight 10). Karpenter schedules on higher-weight pools first, falling back to overlay when SPOT availability is low.

| NodePool | Weight | Instance gen | Capacity |
|---|---|---|---|
| `general-amd64` | 100 | gen 7+ (m7i, m7a, c7i, r7i) | SPOT → ON_DEMAND |
| `general-amd64-overlay` | 10 | gen 5-6 (m5, m6i, c5, r5) | SPOT → ON_DEMAND |
| `general-arm64` | 100 | gen 7+ (m7g, c7g, r7g) | SPOT → ON_DEMAND |
| `general-arm64-overlay` | 10 | gen 5-6 (m5, m6g, c5, r5) | SPOT → ON_DEMAND |

### NodeDisruptionBudget defaults

```
Business hours (09:00–17:00 Mon–Fri): nodes: "0"   → no voluntary disruption
All other times:                       nodes: "10%" → max 10% per cron window
```

Pools are staggered by 5-minute offset to prevent simultaneous fleet replacement waves.

**Why business hours protection:** Karpenter's consolidation replaces nodes aggressively. Without a budget, a consolidation wave can evict many pods simultaneously during working hours, impacting SLOs. The off-hours window allows drift cleanup without production risk.

### Interruption handling

SQS queue receives EC2 SPOT interruption warnings, rebalance recommendations, and health events via EventBridge. Karpenter drains and replaces nodes within the 2-minute interruption window.

`reservedENIs: "1"` — reserves one ENI per node to prevent exhaustion blocking Pod Identity agent communication.

### `Delete=false` ArgoCD sync option

On the NodePool Application — prevents accidental node pool deletion via a misconfigured ArgoCD sync that would drain the entire workload fleet.

---

## GitOps — ArgoCD App-of-Apps

### Bootstrap sequence

**Phase 1 — Terraform:** Installs ArgoCD via Helm, writes runtime values into `platform-env-values` ConfigMap, creates the `platform` ArgoCD Project, applies the root `platform` Application pointing at `cluster-applications/bootstrap/`.

**Phase 2 — Self-managing sync waves:**

```
Wave 1  platform-core
        Namespaces, RBAC, PriorityClasses, APF flowschemas,
        VPA, metrics-server, node-problem-detector, NodeLocal DNSCache, Reloader

Wave 2  platform-networking + platform-secrets
        AWS LBC, Traefik (public + internal), cert-manager, ExternalDNS,
        Retina, External Secrets Operator, ClusterSecretStore

Wave 3  platform-autoscaling (controller)
        Karpenter, KEDA

Wave 4  platform-autoscaling (config)
        Karpenter NodePools + EC2NodeClasses
        (separate wave — controller must be ready before CRD instances)

Wave 5  platform-policy
        Kyverno, Kyverno policies, NetworkPolicy defaults, Cloud Custodian

Wave 6  platform-observability
        OTEL Operator, kube-prometheus-stack, node-exporter,
        Loki, kubernetes-events-exporter, noe, yace

Wave 7  platform-gitops
        ArgoCD Projects, RBAC, AppSet controller config, Velero, Renovate
```

### Runtime values injection

Terraform writes cluster-specific values (domain, clusterName, region, accountId, subnet IDs, SG IDs) into a `platform-env-values` ConfigMap. The root `platform` Application uses `valuesFrom` to read this ConfigMap. Git can never contain these values — they only exist after Terraform applies.

Environment-specific Git overrides (`hostedZoneId`, per-env tuning) live in `cluster-applications/environments/<env>.yaml` and merge on top.

### ArgoCD production tuning

| Setting | Value | Why |
|---|---|---|
| `status.processors` | 50 | Default 10 creates sync queue backlog at scale |
| `operation.processors` | 25 | Default 5; same issue |
| `WORKQUEUE_BUCKET_SIZE/QPS` | MaxInt64 | Prevents controller work-queue throttling (upstream ArgoCD issue) |
| `ServerSideApply=true` | All large CRDs | Avoids `last-applied-configuration` annotation size limit |
| Redis HA | enabled | Single-replica Redis is a silent ArgoCD SPOF |
| Progressive sync | enabled | Required for multi-cluster ApplicationSet extension |
| Velero Backup exclusion | resource.exclusions | High-churn objects pollute diff view and waste compute |

### Multi-cluster extension path

When a second cluster is added, migrate to ArgoCD ApplicationSets with a `clusters` generator and progressive sync. `applicationsetcontroller.enable.progressive.syncs: true` is already set. See README for the ApplicationSet pattern.

---

## Ingress

### Public Traefik

Routes external traffic. Internet-facing NLB (provisioned by AWS LBC) → Traefik in `traefik` namespace.

### Internal Traefik

Routes internal traffic (VPC-internal, service mesh, internal APIs). Internal NLB → Traefik in `traefik-internal` namespace. Services annotate with `kubernetes.io/ingress.class: traefik-internal` to use it.

Both instances run on system nodes (toleration + nodeAffinity). Both are excluded from the default-deny NetworkPolicy (system namespace).

### Why Traefik over Nginx

Nginx Ingress Controller is in maintenance mode (no new features). Traefik is actively developed, has native middleware (rate limiting, headers, auth), and integrates cleanly with cert-manager.

**No resource limits on ingress controller pods.** Hard limits cause CPU throttling during traffic spikes. VPA manages right-sizing via recommendations.

**`post-shutdown-grace-period` (181s) < `terminationGracePeriodSeconds` (200s)** — ensures connections drain before the pod is killed. Reversing this order causes in-flight request errors on pod shutdown.

---

## Policy — Kyverno

### Why Kyverno over OPA/Gatekeeper

Kyverno uses Kubernetes-native YAML for policies — no Rego. Policies are Kubernetes resources: they live in git, are managed by ArgoCD, and are debuggable with `kubectl describe`. The `generate` rule type (auto-create NetworkPolicies per namespace) has no equivalent in OPA.

### Default NetworkPolicies (generated per namespace)

On namespace creation, Kyverno generates five NetworkPolicies:

| Policy | Type | Purpose |
|---|---|---|
| `default-deny-ingress` | Ingress | Baseline tenant isolation |
| `allow-ingress-from-traefik` | Ingress | HTTP/HTTPS routing from public ingress |
| `allow-ingress-from-traefik-internal` | Ingress | Routing from internal ingress |
| `allow-ingress-from-monitoring` | Ingress | Prometheus metric scraping |
| `allow-ingress-same-namespace` | Ingress | Pod-to-pod within namespace |
| `deny-egress-to-kubelet` | Egress | Block TCP 10250 — pods must not reach node kubelet APIs |

All policies use `synchronize: true` — if manually deleted, Kyverno regenerates them.

**Why ingress-only restriction for the default deny:** Egress is left unrestricted except for the kubelet port. This means workloads can reach external services, kube-dns, and system namespaces without extra rules. Only cross-namespace ingress (tenant isolation direction) and kubelet access are locked down.

**Why exclude system namespaces:** They manage their own access patterns and frequently require broader intra-cluster communication (ArgoCD reconciles across all namespaces, Prometheus scrapes everywhere, etc.).

### Kyverno placement: system nodes + `system-cluster-critical`

Eviction of the admission webhook pod causes cluster-wide pod scheduling failures — no new pods can be created until the webhook recovers. System node placement with `system-cluster-critical` priority makes eviction impossible under normal node pressure.

**`Binding`/`Pod/binding` excluded from Kyverno:** Kyverno intercepting pod binding adds ~10-50ms latency per pod placement. At scale, this degrades scheduling throughput significantly.

**`Delete=false` sync option:** Kyverno CRD deletion cascades to CRD removal. With Enforce policies in place, CRD removal causes the admission webhook to fail-close: no pods can be created cluster-wide.

### Security policies

| Policy | Rule | Notes |
|---|---|---|
| `no-latest-image-tag` | Deny | All containers must pin image tags |
| `require-labels` | Enforce | `app.kubernetes.io/name` and `app.kubernetes.io/version` required |
| `require-resource-requests` | Enforce | CPU and memory requests required on all containers |
| `deny-privilege-escalation` | Enforce | `allowPrivilegeEscalation: false` required |
| `restrict-host-namespaces` | Enforce | `hostNetwork`, `hostPID`, `hostIPC` denied for workloads |

---

## Secrets

**External Secrets Operator** pulls from AWS Secrets Manager into Kubernetes Secrets. `ClusterSecretStore` via Pod Identity — no static credentials in cluster. `enable-secrets-caching: true` reduces Secrets Manager API calls.

**No Sealed Secrets** in initial scope. Can be added alongside ESO for the ArgoCD bootstrap chicken-and-egg scenario if needed.

---

## Observability

### Collection — OTEL Operator

`OpenTelemetryCollector` CRD in DaemonSet mode handles log collection (filelog receiver), metric forwarding, and trace receiving in a single agent. Replaces Fluent Bit + separate trace agent with one process per node.

Operator-managed: changing the observability backend is a CRD field update, not an application change.

### Metrics — kube-prometheus-stack

Prometheus Operator + Prometheus + Alertmanager + Grafana. `ServerSideApply=true` + `ServerSideDiff=true` — CRDs exceed client-side apply annotation size limit. Admission webhooks disabled — avoids bootstrap chicken-and-egg ordering.

### Logs — Loki

Log aggregation. OTEL Collector ships logs. Label-indexed storage (cost-efficient vs full-text index).

### Network observability — Retina (Microsoft)

eBPF-based network metrics per node and pod. Surfaces packet drops, latency, DNS errors, and TCP retransmits without application changes. Complements Prometheus metrics with network-layer visibility.

### Capacity — noe (adevinta/noe)

Node overhead estimator — computes actual allocatable capacity accounting for OS/daemon reservations. Surfaces true headroom in Grafana. Prevents scheduling surprises under load ("why can't this pod schedule when nodes show 40% free?").

### AWS metrics — yace (CloudWatch exporter)

Scrapes CloudWatch metrics (RDS, SQS, ALB, EKS) into Prometheus. Full-stack visibility — cluster metrics alone miss the AWS layer. Read-only via Pod Identity.

---

## Reliability

**Velero** — cluster backup/restore. EBS snapshots + manifest export to S3. Excluded from ArgoCD resource tree (high-churn Backup objects create constant diff noise).

**VPA** — right-sizes CPU/memory requests. Recommendation mode by default.
- `min-replicas: 1` — never evicts singleton pods
- `oom-bump-up-ratio: 1.5` — after OOM, bumps recommendation 50% (prevents thrash loops)
- Admission controller at 3 replicas — it's a webhook; single replica = scheduling SPOF

**PriorityClasses** — `system-cluster-critical`, `platform-high`, `platform-default`, `workload-default`. Controls eviction order under node pressure.

**NodeLocal DNSCache** — per-node DNS cache. Eliminates conntrack race conditions under high DNS query rates. Must-have beyond ~50 pods per node.

**Reloader (Stakater)** — watches ConfigMaps/Secrets, triggers rolling restarts after secret rotation. Eliminates stale-config incidents.

---

## Governance

**Cloud Custodian** — AWS resource governance: tag enforcement, unencrypted resource detection, idle asset cleanup. CronJob pulling policies from git. Via Pod Identity with account-wide read + remediation permissions.

**Renovate** — automated dependency update PRs. Runs as a CronJob, opens PRs for Helm chart version bumps, Terraform module updates, and container image tags. Keeps the platform current without manual tracking.

---

## CI/CD

Two GitHub Actions workflows are provided but **disabled by default** (review before enabling):

- **`terraform-plan.yml`** — triggered on PRs touching `live/` or `modules/`. Posts plan output as PR comment. Auth via AWS OIDC (no static credentials).
- **`terraform-apply.yml`** — triggered on merge to main. Applies stacks in dependency order. Posts Slack notification on failure.

---

## Extending the Platform

### Adding a second environment

1. Create `live/staging/env.hcl` with staging-specific values
2. Create `cluster-applications/environments/staging.yaml`
3. Add `values/staging.yaml` to charts with staging-specific overrides

No module changes required.

### Adding a second cluster

All cluster Terragrunt logic lives in `_catalog/cluster/`. Each live cluster is a directory with thin `terragrunt.hcl` files (two `include` lines each):

```
live/production/
  env.hcl                    # cluster identity: cluster_name, region, domain, etc.
  cluster/
    eks/terragrunt.hcl        # include root + _catalog/cluster/eks.hcl
    karpenter/terragrunt.hcl
    argocd-bootstrap/terragrunt.hcl

live/production/cluster-2/
  env.hcl                    # different cluster_name — only file you need to write
  cluster/
    eks/terragrunt.hcl        # identical to above
    karpenter/terragrunt.hcl
    argocd-bootstrap/terragrunt.hcl
```

`find_in_parent_folders("env.hcl")` in the catalog file resolves upward from the live file's location, picking up the correct `env.hcl` for that cluster automatically.

---

## Production Lessons

**ArgoCD:** Increase status/operation processors (50/25) for clusters with many Applications. Set work-queue bucket to MaxInt64 to prevent throttling. Redis HA from day one. Exclude high-churn objects (Velero Backup) from resource tree.

**Karpenter:** `reservedENIs: "1"` prevents ENI exhaustion blocking Pod Identity. `Delete=false` on NodePool Application — accidental deletion drains the fleet. Stagger disruption budget cron windows. Tag every EBS volume with cluster name for cost attribution.

**VPA:** Never set `min-replicas: 0` — evicts singleton pods causing outages. `oom-bump-up-ratio: 1.5` prevents OOM thrash loops.

**cert-manager:** Wave 2 placement — many charts (LBC, Traefik, ESO) use cert-manager for webhook TLS. `crds.keep: true` — without it, `helm uninstall` deletes all Certificate and ClusterIssuer objects.

**ExternalDNS:** `txtOwnerId` must be the cluster name. Without it, a second cluster deletes the first cluster's DNS records. `policy: sync` requires correct ownership.

**kube-prometheus-stack:** Always `ServerSideApply=true` + `ServerSideDiff=true` — CRDs exceed client-side apply annotation limit. Disable admission webhooks to avoid bootstrap ordering issues.

**Traefik:** `post-shutdown-grace-period` must be less than `terminationGracePeriodSeconds`. No hard resource limits — VPA manages sizing, hard limits cause throttling during traffic spikes.

**Kyverno:** Exclude `Binding`/`Pod/binding` — adds scheduling latency. System node placement + `system-cluster-critical` priority — eviction causes cluster-wide scheduling failure.

**EKS API CIDRs:** AWS hard limit of 40 CIDRs for public access — validated in Terraform.
