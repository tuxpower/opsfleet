output "cluster_name" {
  description = "EKS cluster name."
  value       = module.eks.cluster_name
}

output "region" {
  description = "AWS Region."
  value       = var.region
}

output "connection" {
  description = "Connection details consumed by the two subsequent stages."
  value = {
    name                       = module.eks.cluster_name
    region                     = var.region
    endpoint                   = module.eks.cluster_endpoint
    certificate_authority_data = module.eks.cluster_certificate_authority_data
    karpenter_version          = local.karpenter_version
    interruption_queue         = module.karpenter.queue_name
    instance_profile           = module.karpenter.instance_profile_name
    ami_alias                  = local.ami_alias
  }
}

output "kubernetes_version" {
  description = "Pinned EKS minor version."
  value       = local.kubernetes_version
}

output "vpc_id" {
  description = "Dedicated POC VPC."
  value       = module.vpc.vpc_id
}

output "addon_versions" {
  description = "Resolved addon builds; use these as addon_versions pins after testing."
  value       = { for name, addon in module.eks.cluster_addons : name => addon.addon_version }
}
