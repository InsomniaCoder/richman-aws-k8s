# richman-aws-eks — Design Spec

**Date:** 2026-05-20
**Status:** Approved — ready for implementation planning

---

## Overview

`richman-aws-eks` is the production-grade companion to `poorman-aws-k8s`. Where `poorman-aws-k8s` demonstrates how to run Kubernetes on AWS as cheaply as possible (K3S, SPOT, single-AZ, fck-NAT), `richman-aws-eks` demonstrates what you would actually build if downtime, security, and scale matter — a full production platform on EKS.

**Audience:** Startups shipping real products, platform engineers, enterprises evaluating EKS patterns.

**Scope:** Single cluster, single environment (`production`), designed so adding a second environment or cluster requires only a new Terragrunt directory and values file — no module changes.

**What this is not:** A cost-optimized setup. The bill will be real. The value is the pattern.

---

## Project name

`richman-aws-eks` — deliberate contrast with `poorman-aws-k8s`. Same naming convention, opposite intent.

---

## Repository structure

```
richman-aws-eks/
├── root.hcl                              # Terragrunt root: remote_state, provider generate
├── .github/
│   └── workflows/
│       ├── terraform-plan.yml            # PR: plan on changed stacks (disabled, review before enabling)
│       └── terraform-apply.yml           # Merge to main: apply changed stacks (disabled, review before enabling)
├── modules/
│   ├── account/
│   │   ├── vpc/                          # VPC, 3-tier subnets (public/private/pod), NAT GW, endpoints
│   │   ├── iam/                          # Node role, cluster role, Pod Identity associations
│   │   └── ecr/                          # ECR repos, pull-through cache rules
│   └── cluster/
│       ├── eks/                          # EKS control plane, system managed node group, managed addons
│       ├── karpenter/                    # Karpenter IAM, SQS interruption queue, EventBridge rules
│       └── argocd-bootstrap/             # ArgoCD Helm install + root App-of-Apps Application
├── cluster-applications/
│   ├── environments/
│   │   └── production.yaml              # Cross-cutting env values (injected by Terraform at bootstrap)
│   ├── bootstrap/
│   │   ├── Chart.yaml
│   │   └── templates/                   # Root App-of-Apps — generates one Application per platform group
│   ├── platform-core/
│   │   ├── Chart.yaml
│   │   ├── values/base.yaml
│   │   └── values/production.yaml
│   ├── platform-networking/
│   │   ├── Chart.yaml
│   │   ├── values/base.yaml
│   │   └── values/production.yaml
│   ├── platform-autoscaling/
│   │   ├── Chart.yaml
│   │   ├── values/base.yaml
│   │   └── values/production.yaml
│   ├── platform-secrets/
│   │   ├── Chart.yaml
│   │   ├── values/base.yaml
│   │   └── values/production.yaml
│   ├── platform-policy/
│   │   ├── Chart.yaml
│   │   ├── values/base.yaml
│   │   └── values/production.yaml
│   ├── platform-observability/
│   │   ├── Chart.yaml
│   │   ├── values/base.yaml
│   │   └── values/production.yaml
│   └── platform-gitops/
│       ├── Chart.yaml
│       ├── values/base.yaml
│       └── values/production.yaml
└── live/
    └── production/
        ├── env.hcl                       # Single file to edit per environment
        ├── account/
        │   ├── vpc/terragrunt.hcl
        │   ├── iam/terragrunt.hcl
        │   └── ecr/terragrunt.hcl
        └── cluster/
            ├── eks/terragrunt.hcl
            ├── karpenter/terragrunt.hcl
            └── argocd-bootstrap/terragrunt.hcl
```

### Adding a second environment

Create `live/staging/env.hcl` with staging-specific values (smaller nodes, different domain, staging account ID). Create `cluster-applications/environments/staging.yaml`. Add `values/staging.yaml` to any platform chart that needs staging-specific overrides. **No module changes required.**

### Adding a second cluster

Create `live/production/cluster-2/` pointing at the same `modules/cluster/` modules with a different `cluster_name`. Each cluster gets its own ArgoCD bootstrap. The account-level resources (VPC, IAM foundation) are shared.

---

## Environment override strategy

Two layers of configuration:

**Layer 1 — Cross-cutting (`environments/<env>.yaml`):** Values that apply to all platform charts in this environment: `cluster_name`, `region`, `account_id`, `domain`, `vpc_id`, `node_subnets`, `pod_subnets`, `environment`. Written by Terraform into an ArgoCD ConfigMap at bootstrap time (cluster-specific values can't live in git). The bootstrap chart stamps these into every child `Application` it generates.

**Layer 2 — App-specific (`platform-*/values/<env>.yaml`):** Overrides for replica counts, resource sizing, feature flags, environment-specific domain names. Merged on top of `base.yaml` at render time. Only exists where the environment differs from base. Adding staging usually means creating `values/staging.yaml` only in charts where prod and staging diverge.

This keeps one authoritative file for "what is this environment" while each chart stays responsible for its own tuning.

---

## Networking

### VPC topology — 3 AZs, 3 subnet tiers

```
VPC 10.0.0.0/16
│
├── AZ-a
│   ├── Public   10.0.0.0/24     NLB/ALB, NAT Gateway — no nodes
│   ├── Private  10.0.10.0/24    System nodes, Karpenter nodes
│   └── Pod      10.0.64.0/18    Pod IPs only (VPC CNI ENIConfig)
│
├── AZ-b
│   ├── Public   10.0.1.0/24
│   ├── Private  10.0.11.0/24
│   └── Pod      10.0.128.0/18
│
└── AZ-c
    ├── Public   10.0.2.0/24
    ├── Private  10.0.12.0/24
    └── Pod      10.0.192.0/18
```

**Why dedicated pod subnets:** With VPC CNI custom networking (`AWS_VPC_K8S_CNI_CUSTOM_NETWORK_CFG=true`), pod IPs come from the pod subnets rather than the node subnets. This solves IP exhaustion — a /24 node subnet has 251 usable IPs which could be exhausted by ~30 nodes; /18 pod subnets have 16,384 IPs each. Combined with prefix delegation (`ENABLE_PREFIX_DELEGATION=true`), a single m6i.2xlarge can run 100+ pods by receiving /28 blocks (16 IPs) per ENI prefix rather than one IP per ENI slot.

**Pod subnet ENIConfig:** Each pod subnet is tagged `topology.kubernetes.io/zone=<az>` matching the VPC CNI `ENI_CONFIG_LABEL_DEF` setting. The CNI selects the correct subnet automatically based on the node's AZ label — no manual mapping needed.

**NAT Gateways:** One per AZ (3 total) to avoid cross-AZ data transfer charges on pod egress. At scale, the cross-AZ savings exceed the extra NAT cost. Controlled by `single_nat_gateway` variable — set to `true` for dev/cost-sensitive environments.

**EKS API server public access:** Enabled, scoped to `admin_cidr` variable (typically your IP or VPN CIDR). **Hard limit: AWS allows at most 40 CIDRs for public access — validated by Terraform.**

### VPC Endpoints

| Endpoint | Type | Why |
|---|---|---|
| S3 | Gateway (free) | ECR layer pulls, Velero S3 backups, Terraform state — stays on AWS backbone |
| ECR API + DKR | Interface | Node image pulls without NAT traffic |
| Secrets Manager | Interface | ESO secret fetches stay private |
| SSM | Interface | Session Manager access, SSM Parameter Store |
| STS | Interface | Pod Identity token exchanges |
| EC2 | Interface | Karpenter instance provisioning |

Interface endpoints cost ~$7/mo each per AZ, deployed across all 3 AZs for HA. Controlled by `create_vpc_endpoints` variable.

### Security groups

- `sg-control-plane` — EKS control plane; allows 443 inbound from `sg-nodes`
- `sg-nodes` — all nodes (system + Karpenter); full bidirectional within itself, 443 outbound to `sg-control-plane`
- `sg-nlb` — attached to the NLB; allows 80/443 from `0.0.0.0/0`, forwards to `sg-nodes`

### NetworkPolicy enforcement

AWS VPC CNI network policy controller (enabled via `NETWORK_POLICY_ENFORCING_MODE=standard` on the VPC CNI addon). **No separate CNI plugin needed** — policy enforcement is native to the VPC CNI. Kyverno generates a default-deny ingress NetworkPolicy for every new namespace, with explicit allows for DNS (53/UDP+TCP to kube-system), metrics scraping (from monitoring namespace), and webhook traffic (443 from API server).

---

## IAM & Pod Identity

### Why Pod Identity over IRSA

EKS Pod Identity (GA since EKS 1.24, 2023) is simpler to operate:
- No OIDC provider URL to maintain
- No token projection annotation on every ServiceAccount
- No trust policy tied to a specific cluster OIDC issuer — same role works across clusters
- `aws_eks_pod_identity_association` in Terraform — one resource per service account

**Pod Identity is the only mechanism used in this project.** IRSA is not implemented but is documented for cross-account scenarios where Pod Identity does not reach. See the README section "Using IRSA for cross-account access."

### Account-level roles (created once in `modules/account/iam/`)

| Role | Purpose | Policies |
|---|---|---|
| `eks-cluster-role` | Assumed by EKS control plane | `AmazonEKSClusterPolicy` |
| `eks-node-role` | Attached to all EC2 nodes | `AmazonEKSWorkerNodePolicy`, `AmazonEC2ContainerRegistryReadOnly`, `AmazonSSMManagedInstanceCore`, ECR pull-through cache |

Node role has no application permissions — those are granted exclusively via Pod Identity.

### Pod Identity associations (created in `modules/cluster/eks/`)

Implemented as a map variable — adding a new service account is one entry in `terraform.tfvars`:

| Service Account | Namespace | Permissions |
|---|---|---|
| `karpenter` | `karpenter` | EC2 Fleet, SQS read, pricing, SSM, `iam:PassRole` (node role only, condition-scoped) |
| `aws-load-balancer-controller` | `kube-system` | ELB full, EC2 describe, WAF |
| `external-dns` | `external-dns` | Route 53 `ChangeResourceRecordSets` (scoped to hosted zone ID) |
| `external-secrets` | `external-secrets` | Secrets Manager `GetSecretValue`, `DescribeSecret` |
| `ebs-csi-controller` | `kube-system` | EC2 volume lifecycle |
| `velero` | `velero` | S3 read/write (backup bucket), EC2 snapshot |
| `cloud-custodian` | `cloud-custodian` | Account-wide read + tag/remediation actions |
| `yace` | `monitoring` | CloudWatch `GetMetricData`, `ListMetrics` (read-only) |

### Admin access

EKS access entries (not `aws-auth` ConfigMap — legacy, being deprecated). SSO admin roles granted `AmazonEKSClusterAdminPolicy` via `aws_eks_access_policy_association`. No static kubeconfig credentials. `kubectl` requires a valid AWS session.

---

## EKS cluster configuration

### Managed addons (pinned versions via `addon_versions` map variable)

| Addon | Notes |
|---|---|
| `vpc-cni` | `ENABLE_PREFIX_DELEGATION=true`, `AWS_VPC_K8S_CNI_CUSTOM_NETWORK_CFG=true`, `ENI_CONFIG_LABEL_DEF=topology.kubernetes.io/zone`, `NETWORK_POLICY_ENFORCING_MODE=standard`. ENIConfig objects created per AZ pointing at pod subnets. |
| `kube-proxy` | Managed lifecycle, no custom config. |
| `coredns` | Managed lifecycle, no custom config. |
| `aws-ebs-csi-driver` | Managed lifecycle. |
| `eks-pod-identity-agent` | Tolerates all system taints so it runs on system nodes. |

### System node group

Fixed-size ON_DEMAND managed node group for cluster-critical components (Karpenter, ArgoCD, cert-manager, Kyverno admission webhook, VPA admission controller, OTEL Operator):

- **Instance type:** `m6i.xlarge` (primary) with same-spec fallback instances via `data.aws_ec2_instance_types` filter matching vCPU + memory
- **Sizing:** `min=2, desired=2, max=4`, ON_DEMAND, multi-AZ (one per AZ)
- **Taint:** `system-node=true:NoSchedule` — workloads must explicitly tolerate to run here
- **Label:** `node.kubernetes.io/role=system`
- **Root EBS:** 100 GB gp3

System nodes are not autoscaled. Scaling is a deliberate Terraform change (`desired_size`). System component resource requirements are stable and predictable — autoscaling adds complexity with no benefit here.

### Kubernetes version policy

`kubernetes_version` in `env.hcl`. EKS minor version upgrades are applied by updating this variable and running `terragrunt apply` — EKS performs a managed rolling upgrade. Node groups update via new launch template version (`eks_ami_release_version` variable) + rolling replacement.

---

## Node autoscaling — Karpenter

Karpenter runs on system nodes (toleration + nodeAffinity for `system-node=true`), provisions workload nodes via EC2 Fleet.

### NodePool design

| NodePool | Capacity type | Instance family | Purpose |
|---|---|---|---|
| `general-amd64` | SPOT → ON_DEMAND fallback | m6i, m6a, m7i, m7a (4-32 vCPU) | General workloads |
| `general-arm64` | SPOT → ON_DEMAND fallback | m6g, m7g (4-32 vCPU) | ARM-compatible workloads |
| `system-critical` | ON_DEMAND only | m6i, m7i | Workloads requiring guaranteed capacity |

**SPOT interruption handling:** SQS queue receives EC2 SPOT interruption warnings, rebalance recommendations, and health events via EventBridge rules. Karpenter drains and replaces nodes gracefully within the 2-minute interruption window. **`reservedENIs: "1"` is set** on Karpenter — reserves one ENI per node to prevent exhaustion that would block Pod Identity agent communication.

**Disruption budgets:** Each NodePool has a disruption budget (e.g., `maxUnavailable: 1` per 15-minute window) staggered between pools to prevent simultaneous drift-replacement waves.

**`delete=false` sync option** on the Karpenter NodePool ArgoCD Application — prevents accidental node pool deletion via a bad ArgoCD sync.

EC2NodeClass tags every provisioned EBS volume with `Cluster: <cluster_name>` for cost attribution.

---

## GitOps / ArgoCD bootstrap

### Phase 1 — Terraform (automated)

The `argocd-bootstrap` Terragrunt stack:
1. Installs ArgoCD via Helm (pinned version)
2. Configures ArgoCD with tuned settings (see Production lessons below)
3. Writes `environments/production.yaml` into an ArgoCD ConfigMap (cluster-specific runtime values)
4. Creates the `platform` ArgoCD Project (source repo + destination cluster locked)
5. Applies the root App-of-Apps `Application` pointing at `cluster-applications/bootstrap/`

After step 5, ArgoCD self-manages everything. Terraform never touches `cluster-applications` again.

### Phase 2 — ArgoCD sync waves (self-managing)

```
Wave 1  platform-core
        namespaces, RBAC, PriorityClasses, APF flowschemas,
        VPA, metrics-server, node-problem-detector, NodeLocal DNSCache, Reloader

Wave 2  platform-networking + platform-secrets
        AWS LBC, Traefik, cert-manager, ExternalDNS,
        External Secrets Operator, ClusterSecretStore

Wave 3  platform-autoscaling (controller)
        Karpenter, KEDA

Wave 4  platform-autoscaling (config)
        Karpenter NodePools + EC2NodeClasses
        (separate wave — controller must be ready before CRD instances are created)

Wave 5  platform-policy
        Kyverno, Kyverno policies, NetworkPolicy defaults, Cloud Custodian

Wave 6  platform-observability
        OTEL Operator, kube-prometheus-stack, node-exporter,
        Loki, kubernetes-events-exporter, noe, yace

Wave 7  platform-gitops
        ArgoCD Projects, RBAC, AppSet controller config, Velero
```

### ArgoCD configuration (production-tuned)

Based on lessons from operating ArgoCD at scale:

- **`status.processors: 50` / `operation.processors: 25`** — scaled up from defaults (10/5) to handle many Applications without sync queue buildup
- **`WORKQUEUE_BUCKET_SIZE` and `WORKQUEUE_BUCKET_QPS` set to `MaxInt64`** — prevents controller work-queue throttling at scale (upstream ArgoCD issue)
- **Custom health checks for Deployment/DaemonSet** — 75% updated+ready = Healthy, <10% = Degraded (more tolerant than defaults, prevents false Degraded during rolling updates)
- **Custom health check for `Application` CRD** — Application is Progressing until `syncStatus=Synced`, preventing parent apps showing Healthy while children are still syncing
- **`resource.exclusions`: Velero Backup objects** — high-churn objects excluded from ArgoCD resource tree to prevent constant diff computation
- **`applicationsetcontroller.enable.progressive.syncs: true`** — enables wave-based progressive sync in ApplicationSets (required for multi-cluster extension)
- **`ServerSideApply=true`** on all charts with large CRDs (kube-prometheus-stack, Kyverno, KEDA) — avoids `kubectl.kubernetes.io/last-applied-configuration` annotation size limit
- **`ServerSideDiff=true`** companion annotation — uses server-side diff to avoid false positives in ArgoCD UI when SSA is active
- **Redis HA enabled** — single-replica Redis is a single point of failure for ArgoCD; HA mode from day one

### Multi-cluster extension path (ApplicationSets + Progressive Sync)

When you add a second cluster, the pattern to adopt is **ArgoCD ApplicationSets with progressive sync**:

Instead of one `Application` per cluster per platform component, an `ApplicationSet` with a `clusters` generator creates Applications across all clusters automatically. Progressive sync (`syncPolicy.progressive.steps`) rolls changes through clusters in waves — for example: `staging` first, wait for healthy, then `production`. This gives you canary-style rollout of platform changes across your fleet.

```yaml
# Example: progressive multi-cluster rollout
spec:
  generators:
  - clusters:
      selector:
        matchLabels:
          environment: staging   # wave 1
  - clusters:
      selector:
        matchLabels:
          environment: production  # wave 2
  strategy:
    type: Progressive
    progressive:
      steps:
      - match:
          labelSelector:
            matchLabels:
              environment: staging
      - match:
          labelSelector:
            matchLabels:
              environment: production
        maxUpdate: "25%"   # roll 25% of prod clusters at a time
```

`applicationsetcontroller.enable.progressive.syncs: true` is already enabled in our ArgoCD config in preparation for this.

---

## Platform components

### Full component table

| Component | Group | Why |
|---|---|---|
| **AWS VPC CNI** (managed addon) | Networking | Native VPC IPs, no overlay. Prefix delegation solves IP exhaustion. Custom networking uses dedicated pod subnets. **NetworkPolicy enforcement built-in** via VPC CNI policy controller — no Calico needed. |
| **kube-proxy** (managed addon) | Networking | Service iptables. AWS-managed lifecycle. |
| **EBS CSI Driver** (managed addon) | Storage | EBS provisioner. `WaitForFirstConsumer` binding ensures volume lands in same AZ as pod. `volumeModificationFeature` enabled for in-place resize. Tags all volumes with `Cluster: <name>` for cost attribution. |
| **EKS Pod Identity Agent** (managed addon) | IAM | Tolerates system node taint. Handles Pod Identity token exchange locally on the node. |
| **metrics-server** | Core | Required by HPA and VPA. Not included in EKS by default. |
| **VPA** | Core | Right-sizes CPU/memory requests. Recommendation mode by default. `InPlaceOrRecreate` feature gate avoids pod eviction for CPU changes. `min-replicas: 1` — never evicts singleton pods. `oom-bump-up-ratio: 1.5` — after OOM, bumps recommendation 50%. Admission controller at 3 replicas (HA for webhook). |
| **node-problem-detector** | Core | DaemonSet — surfaces kernel OOMs, disk pressure, NTP drift as K8s events + Prometheus metrics. Tolerates all taints to run on every node type. |
| **NodeLocal DNSCache** | Core | Per-node DNS cache. Eliminates conntrack race conditions under high DNS query rates. Must-have beyond ~50 pods/node. |
| **Reloader** (Stakater) | Core | Watches ConfigMaps/Secrets, triggers rolling restarts. Eliminates stale-config incidents after secret rotation. |
| **PriorityClasses** | Core | `system-cluster-critical`, `platform-high`, `platform-default`, `workload-default`. Controls eviction order under node pressure. |
| **API PriorityAndFairness flowschemas** | Core | Prevents noisy workloads from starving the API server. |
| **Karpenter** | Autoscaling | EC2 Fleet provisioning. SPOT-first, ON_DEMAND fallback. SQS interruption queue. `reservedENIs: "1"`. Runs on system nodes. |
| **Karpenter NodePools + EC2NodeClasses** | Autoscaling | Separate sync wave from controller. NodePool = scheduling + limits. EC2NodeClass = AMI, subnets, SGs, instance profile. Staggered disruption budgets between pools. |
| **KEDA** | Autoscaling | Event-driven HPA — SQS depth, Kafka lag, Prometheus queries, cron. Scales pods; Karpenter scales nodes. `ServerSideApply=true` (large CRDs). |
| **AWS Load Balancer Controller** | Ingress | Provisions NLB (L4) in front of Traefik. Also provisions ALBs directly for services needing WAF. `enableServiceMutatorWebhook: false` — annotations must be set explicitly, avoids unintended LB creation. `enableCertManager: true` — webhook TLS via cert-manager. |
| **Traefik** | Ingress | L7 ingress behind NLB. TLS termination, routing, middleware. `terminationGracePeriodSeconds: 200` / `post-shutdown-grace-period: 181` — ensures connections drain before pod dies. `maxUnavailable: 0` rolling update + PDB 50% minAvailable. CPU/memory limits intentionally absent on the ingress controller pods — hard limits cause throttling during traffic spikes; VPA manages right-sizing via recommendations. |
| **cert-manager** | Ingress | TLS automation via Let's Encrypt DNS-01 (Route 53). `crds.keep: true` — CRDs preserved on uninstall. `maxConcurrentChallenges: 15`. Wave 1 placement — other apps depend on cert-manager webhook being ready. |
| **ExternalDNS** | Ingress | Route 53 record automation. `policy: sync` (creates AND deletes). `txtOwnerId: <cluster_name>` — critical for multi-cluster setups to prevent one cluster deleting another's records. `--zone-id-filter` scoped to one hosted zone. `--exclude-record-types=AAAA` (IPv4 only). |
| **External Secrets Operator** | Secrets | AWS Secrets Manager → Kubernetes Secrets. `ClusterSecretStore` via Pod Identity. `enable-secrets-caching: true`. No static credentials in cluster. |
| **Kyverno** | Policy | Validation, mutation, generation. Enforces: resource requests/limits required, no `latest` tags, default NetworkPolicy per namespace, required labels. Admission controller on system nodes + `system-cluster-critical` priority (webhook must not be evicted). `min-replicas: 3` for admission controller HA. `resourceFiltersExclude: [Binding, Pod/binding]` — prevents Kyverno intercepting pod binding (scheduling latency). `ServerSideApply=true`. |
| **RBAC + ClusterReadonlyRoles** | Security | Read-only cluster role for developers. Namespace-scoped roles for CI service accounts. |
| **Cloud Custodian** | Governance | AWS resource governance — tag enforcement, unencrypted resource detection, idle asset cleanup. Runs as CronJob. Policies pulled from git. |
| **OTEL Operator** | Observability | `OpenTelemetryCollector` CRD in DaemonSet mode: collects logs via `filelog` receiver, forwards metrics + traces. Replaces Fluent Bit — one agent. `Instrumentation` CRD for pod auto-instrumentation. Backend-agnostic. |
| **kube-prometheus-stack** | Observability | Prometheus Operator + Prometheus + Alertmanager + Grafana. `ServerSideApply=true` + `ServerSideDiff=true` (CRDs too large for client-side apply). `admissionWebhooks.enabled: false` — avoids bootstrap chicken-and-egg. `secretFieldSelector` excludes dockercfg/TLS/SA tokens — reduces API watch load. |
| **node-exporter** | Observability | Host-level metrics per node. Required for node dashboards. |
| **Loki** | Observability | Log aggregation. OTEL Collector ships logs here. Label-indexed (cost-efficient). |
| **kubernetes-events-exporter** | Observability | Exports K8s events (OOMKill, image pull errors, scheduling failures) to Loki. |
| **noe** (adevinta/noe) | Observability | Node overhead estimator — computes actual allocatable capacity accounting for OS/daemon reservations. Surfaces true headroom in Grafana. Prevents scheduling surprises under load. |
| **prometheus-yace-cloudwatch-exporter** | Observability | Scrapes AWS CloudWatch metrics (RDS, SQS, ALB, EKS) into Prometheus. Full-stack visibility — cluster metrics alone miss the AWS layer. Read-only CloudWatch via Pod Identity. |
| **Velero** | Reliability | Cluster backup/restore. EBS snapshots + manifest export to S3. Disaster recovery + cluster migration. Excluded from ArgoCD resource tree (high-churn Backup objects). |
| **ArgoCD** | GitOps | Bootstrapped by Terraform. Self-manages post-bootstrap. Progressive sync enabled for multi-cluster extension. |

---

## CI/CD — GitHub Actions

Two workflows are provided in `.github/workflows/` but **disabled by default** (no triggers configured). Review and enable when ready:

### `terraform-plan.yml` (PR workflow)

Triggers on pull requests that touch `live/` or `modules/`. For each changed Terragrunt stack:
1. `terragrunt init`
2. `terragrunt plan` — output posted as PR comment
3. Plan output is non-blocking (informational only on PR)

Authentication via AWS OIDC (no static credentials in GitHub secrets) — `aws-actions/configure-aws-credentials` with `role-to-assume`.

### `terraform-apply.yml` (merge workflow)

Triggers on merge to `main` for paths matching `live/`. For each changed stack in dependency order:
1. `terragrunt init`
2. `terragrunt apply -auto-approve`
3. On failure: post Slack notification (webhook URL in GitHub secret)

Stack ordering: `account/vpc` → `account/iam` → `account/ecr` → `cluster/eks` → `cluster/karpenter` → `cluster/argocd-bootstrap`

**To enable:** Uncomment the `on:` trigger blocks and configure: `AWS_ROLE_ARN` (GitHub OIDC role), `SLACK_WEBHOOK_URL` (optional).

---

## Technology choices — rationale

### EKS over self-managed Kubernetes
AWS manages control plane availability, etcd backups, API server scaling, and version upgrades. The `$72/mo` EKS fee buys freedom from operating the most critical component. For a showcase targeting startups and enterprises, EKS is what they will encounter in practice.

### AWS VPC CNI + prefix delegation over Cilium/Calico
Pods get native VPC IPs — no overlay, no encapsulation CPU overhead, direct integration with AWS security groups. Prefix delegation with custom networking solves the IP exhaustion problem that makes plain VPC CNI impractical at scale. NetworkPolicy is enforced by the VPC CNI policy controller natively — no separate plugin. The tradeoff: less rich L7 policy than Cilium, but sufficient for the standard ingress/egress segmentation patterns most teams need.

### EKS Pod Identity over IRSA
Pod Identity requires no per-ServiceAccount annotation, no OIDC provider URL in trust policies, and no token projection configuration. The same IAM role can be reused across clusters. For cross-account access (e.g., central secrets account) where Pod Identity does not reach, IRSA remains the correct tool — documented in the README.

### Karpenter over Cluster Autoscaler
Cluster Autoscaler scales existing ASGs — it is bounded by the instance types defined at ASG creation. Karpenter provisions directly via EC2 Fleet, choosing from any instance type matching constraints at the time of scheduling. This means better SPOT availability (wider fallback), faster node provisioning, and intelligent bin-packing (consolidation). The fixed system node group removes the bootstrapping problem — Karpenter always has nodes to run on.

### Traefik over Nginx Ingress Controller
Nginx Ingress Controller is in maintenance mode (no new features). Traefik is actively developed, has native middleware support (rate limiting, headers, auth), and integrates cleanly with cert-manager. Backed by AWS LBC's NLB at L4 — AWS-native load balancing at the edge, portable L7 routing inside.

### External Secrets Operator over Sealed Secrets (for now)
ESO keeps secrets in AWS Secrets Manager — rotatable, auditable, accessible to non-Kubernetes tooling. Sealed Secrets encrypts secrets for git storage, which solves a different problem (GitOps-native bootstrap secrets). Sealed Secrets can be added alongside ESO for the ArgoCD bootstrap chicken-and-egg scenario. Not included in initial scope to keep the bootstrap flow simple.

### OTEL Operator as unified collection agent
The OTEL Collector in DaemonSet mode handles log collection (filelog receiver), metric forwarding, and trace receiving in a single agent. This replaces Fluent Bit (log collection only) with one agent instead of two, reduces per-node resource overhead, and decouples applications from the observability backend — changing the metrics or tracing backend is a CRD change, not an application change.

### Kyverno over OPA/Gatekeeper
Kyverno uses Kubernetes-native YAML for policies (no Rego). Policies are Kubernetes resources — they live in git, are managed by ArgoCD, and are debuggable with `kubectl describe`. The `generate` rule type (auto-create NetworkPolicies per namespace) has no equivalent in OPA.

---

## Production lessons (from operating EKS at scale)

The following are non-obvious configuration decisions extracted from real production EKS clusters, applied in this project:

**ArgoCD at scale:**
- Increase `status.processors` and `operation.processors` well above defaults (50/25) for clusters with many Applications
- Set work-queue bucket size to MaxInt64 to prevent sync throttling (upstream ArgoCD issue)
- Exclude Velero Backup objects from ArgoCD resource tree — they are high-churn and pollute the diff view
- Custom health checks on Application CRD prevent parent apps showing Healthy while children are still syncing
- Redis HA from day one — single-replica Redis is a silent ArgoCD SPOF

**VPA:**
- Never set `min-replicas: 0` on the VPA updater — it will evict singleton pods, causing outages
- Admission controller needs ≥3 replicas — it is a webhook, a single replica is a cluster-wide scheduling SPOF
- `oom-bump-up-ratio: 1.5` prevents OOM thrash loops where VPA repeatedly recommends marginally more memory

**Karpenter:**
- `reservedENIs: "1"` prevents ENI exhaustion blocking Pod Identity agent communication
- `delete=false` ArgoCD sync option on NodePool Application — accidental NodePool deletion would drain the entire workload fleet
- Stagger disruption budget cron windows between NodePools to avoid simultaneous fleet replacement waves
- Tag every EBS volume with `Cluster: <name>` via EC2NodeClass `blockDeviceMappings` — required for cost attribution in multi-cluster accounts

**EKS API server CIDRs:**
- AWS hard limit: 40 CIDRs for public API access. Validate in Terraform before hitting it in production.

**Kyverno:**
- Exclude `Binding` and `Pod/binding` from Kyverno intercepting — adds latency to every pod scheduling operation
- Admission controller must run on system nodes with `system-cluster-critical` priority — eviction of webhook pods causes cluster-wide pod scheduling failures
- Extra RBAC for `argoproj.io/*` resources allows Kyverno policies to validate ArgoCD Application objects

**cert-manager:**
- Wave 1 placement — many other charts (LBC, Traefik, ESO) use cert-manager for webhook TLS. cert-manager must be healthy before they install
- `crds.keep: true` — without this, `helm uninstall` deletes all Certificate and ClusterIssuer objects

**ExternalDNS:**
- `txtOwnerId` must be set to the cluster name. Without it, a second cluster will delete the first cluster's DNS records
- `policy: sync` (not `upsert-only`) — records are cleaned up when Ingresses are deleted; requires correct ownership tracking

**kube-prometheus-stack:**
- CRDs exceed client-side apply annotation limit — always use `ServerSideApply=true` + `ServerSideDiff=true`
- Disable operator admission webhooks (`admissionWebhooks.enabled: false`) — avoids bootstrap ordering issues

**Traefik:**
- `post-shutdown-grace-period` must be less than `terminationGracePeriodSeconds` (e.g., 181s vs 200s) — otherwise the pod is killed before connections finish draining
- Resource limits intentionally absent on ingress controllers — VPA manages sizing, and hard limits cause throttling during traffic spikes

---

## Open questions / future work

- **Cluster upgrade strategy:** Documented as a manual Terraform variable bump + node group rolling replacement. A more automated blue/green cluster upgrade path (provision new cluster → migrate ArgoCD → cut DNS) is worth a separate design.
- **Sealed Secrets:** Not included in initial scope. Add alongside ESO when the bootstrap chicken-and-egg problem surfaces in practice.
- **Multi-cluster ApplicationSets:** Architecture is ready (`progressive.syncs: true`, `environments/` pattern). The ApplicationSet migration guide should be written when a second cluster is added.
- **Tenant namespacing:** Kyverno generates default-deny NetworkPolicies per namespace. Tenant RBAC (namespace-scoped roles for application teams) is scaffolded in `platform-core` RBAC but team-specific bindings are out of scope.
