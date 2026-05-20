# richman-aws-eks

> Production-grade Kubernetes on AWS. The full platform you'd actually build.

The companion to [poorman-aws-k8s](https://github.com/insomniacoder/poorman-aws-k8s) — same AWS region, opposite intent. Where `poorman-aws-k8s` minimizes cost, `richman-aws-eks` demonstrates what production looks like: EKS, multi-AZ, Karpenter, full GitOps, observability, policy, and security.

## What's inside

| Layer | Components |
|---|---|
| Compute | EKS 1.31+, system managed node group (ON_DEMAND), Karpenter (gen 7+ preferred + overlay fallback, business-hours disruption budget), KEDA |
| Networking | VPC CNI + prefix delegation + NetworkPolicy enforcement, 3-tier × 3-AZ subnets, AWS LBC + Traefik (public + internal), Retina (eBPF network metrics) |
| Security | Kyverno policies, RBAC, default-deny NetworkPolicies, kubelet port block, privilege escalation deny, EKS Pod Identity |
| Secrets | External Secrets Operator + AWS Secrets Manager |
| Observability | OTEL Operator, kube-prometheus-stack, Loki, noe, yace (CloudWatch) |
| GitOps | ArgoCD App-of-Apps with 7 sync waves, progressive sync enabled, Renovate (dependency updates) |
| Reliability | Velero backups, VPA, PriorityClasses |
| Governance | Cloud Custodian |


## Prerequisites

- AWS CLI v2 (authenticated: `aws sts get-caller-identity`)
- Terraform ≥ 1.10
- Terragrunt v1
- kubectl
- helm
- A domain hosted in Route 53

## First deploy

### 1. Configure

Edit `live/production/env.hcl`:
```hcl
region       = "eu-west-1"
cluster_name = "richman-production"
domain_name  = "yourdomain.com"
```

Set environment variables:
```bash
export TF_VAR_ADMIN_CIDR="$(curl -s https://checkip.amazonaws.com)/32"
export DOMAIN_NAME="yourdomain.com"
export REPO_URL="https://github.com/your-org/richman-aws-eks"
```

### 2. Bootstrap S3 state bucket (once)
```bash
cd live/production/account/bootstrap && terragrunt apply
```

### 3. Deploy account-level infrastructure
```bash
cd live/production/account/vpc      && terragrunt apply
cd live/production/account/iam      && terragrunt apply
cd live/production/account/ecr      && terragrunt apply
```

### 4. Deploy cluster
```bash
cd live/production/cluster/eks              && terragrunt apply
cd live/production/cluster/karpenter        && terragrunt apply
cd live/production/cluster/argocd-bootstrap && terragrunt apply
```

After `argocd-bootstrap` applies, ArgoCD installs and syncs all platform components automatically via the App-of-Apps. Allow 10–15 minutes for all sync waves to complete.

### 5. Access ArgoCD
```bash
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
# Open https://argocd.<your-domain>
```

### 6. Access Grafana
```bash
# Open https://grafana.<your-domain>
# Login: admin / password set in kubePrometheusStack.grafanaAdminPassword
```

## Adding a second environment

1. Create `live/staging/env.hcl` with staging-specific values
2. Create `cluster-applications/environments/staging.yaml`
3. Add `values/staging.yaml` to any chart with staging-specific overrides
4. Deploy: `cd live/staging && terragrunt run --all apply`

No module changes required.

## Adding a second cluster

```bash
cp -r live/production live/production-2
# Edit live/production-2/env.hcl — change cluster_name (and optionally region, AZs)
# The 6 stack files (account/vpc, account/iam, account/ecr, cluster/eks,
# cluster/karpenter, cluster/argocd-bootstrap) each contain 2 lines and need no editing.
```

Deploy:
```bash
cd live/production-2/account/vpc && terragrunt apply
# ... same sequence as First deploy step 3-4
```

For multi-cluster GitOps with canary rollouts, see `ARCHITECTURE.md` § "Extending the Platform" for the ApplicationSet progressive sync pattern.

## Using IRSA for cross-account access

Pod Identity is used for all in-cluster AWS access. For cross-account scenarios where Pod Identity doesn't reach (e.g. assuming a role in a central secrets account), add an IRSA annotation to the ServiceAccount:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::<account>:role/<role-name>
```

The EKS cluster already has an OIDC provider configured.

## Design principles

See [`ARCHITECTURE.md`](ARCHITECTURE.md) for rationale on every technology choice.

## License

MIT
