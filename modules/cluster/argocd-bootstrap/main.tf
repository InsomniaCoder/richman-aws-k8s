data "aws_eks_cluster" "main" {
  name = var.cluster_name
}
data "aws_eks_cluster_auth" "main" {
  name = var.cluster_name
}

locals {
  common_tags = merge(var.tags, {
    Project     = var.project_name
    Environment = var.environment
    Cluster     = var.cluster_name
  })
}

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.argocd_version
  namespace        = "argocd"
  create_namespace = true
  wait             = true
  timeout          = 600

  # Tolerate system nodes so ArgoCD runs on the system node group
  set {
    name  = "global.tolerations[0].key"
    value = "system-node"
  }
  set {
    name  = "global.tolerations[0].operator"
    value = "Equal"
  }
  set {
    name  = "global.tolerations[0].value"
    value = "true"
  }
  set {
    name  = "global.tolerations[0].effect"
    value = "NoSchedule"
  }

  set { name = "controller.replicas";     value = "1" }
  set { name = "server.replicas";         value = "2" }
  set { name = "repoServer.replicas";     value = "2" }
  set { name = "applicationSet.replicas"; value = "2" }

  set { name = "controller.env[0].name";  value = "WORKQUEUE_BUCKET_SIZE" }
  set { name = "controller.env[0].value"; value = "9223372036854775807" }
  set { name = "controller.env[1].name";  value = "WORKQUEUE_BUCKET_QPS" }
  set { name = "controller.env[1].value"; value = "9223372036854775807" }

  set { name = "controller.extraArgs[0]"; value = "--status-processors=50" }
  set { name = "controller.extraArgs[1]"; value = "--operation-processors=25" }

  set { name = "redis-ha.enabled"; value = "true" }
  set { name = "redis.enabled";    value = "false" }

  set { name = "applicationSet.extraArgs[0]"; value = "--enable-progressive-syncs" }

  set {
    name  = "server.config.resource\\.exclusions"
    value = "- apiGroups:\\n  - velero.io\\n  kinds:\\n  - Backup\\n  clusters:\\n  - '*'"
  }
}

# Root App-of-Apps — points ArgoCD at cluster-applications/bootstrap/
resource "kubernetes_manifest" "app_of_apps" {
  manifest = {
    apiVersion = "argoproj.io/v1alpha1"
    kind       = "Application"
    metadata = {
      name      = "platform"
      namespace = "argocd"
      annotations = {
        "argocd.argoproj.io/sync-wave" = "0"
      }
    }
    spec = {
      project = "default"
      source = {
        repoURL        = var.repo_url
        targetRevision = "HEAD"
        path           = "cluster-applications/bootstrap"
        helm = {
          valueFiles = ["../../cluster-applications/environments/${var.environment}.yaml"]
        }
      }
      destination = {
        server    = "https://kubernetes.default.svc"
        namespace = "argocd"
      }
      syncPolicy = {
        automated = {
          prune    = true
          selfHeal = true
        }
        syncOptions = ["CreateNamespace=true"]
      }
    }
  }
  depends_on = [helm_release.argocd]
}
