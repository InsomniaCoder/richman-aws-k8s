output "cluster_name"        { value = aws_eks_cluster.main.name }
output "cluster_endpoint"    { value = aws_eks_cluster.main.endpoint }
output "cluster_ca"          { value = aws_eks_cluster.main.certificate_authority[0].data }
output "cluster_oidc_issuer" { value = aws_eks_cluster.main.identity[0].oidc[0].issuer }
output "node_sg_id"          { value = aws_security_group.nodes.id }
output "nlb_sg_id"           { value = aws_security_group.nlb.id }
