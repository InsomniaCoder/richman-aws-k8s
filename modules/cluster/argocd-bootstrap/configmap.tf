resource "kubernetes_config_map" "env_values" {
  metadata {
    name      = "platform-env-values"
    namespace = "argocd"
  }

  data = {
    "values.yaml" = yamlencode({
      clusterName         = var.cluster_name
      environment         = var.environment
      region              = var.region
      accountId           = var.account_id
      domain              = var.domain_name
      vpcId               = var.vpc_id
      privateSubnetIds    = var.private_subnet_ids
      podSubnetIds        = var.pod_subnet_ids
      availabilityZones   = var.availability_zones
      nlbSecurityGroupId  = var.nlb_sg_id
      nodeSecurityGroupId = var.node_sg_id
    })
  }

  depends_on = [helm_release.argocd]
}
