locals {
  # Verified on 2026-09-14. Upgrade these together after checking compatibility.
  kubernetes_version = "1.36"
  karpenter_version  = "1.14.1"
  ami_alias          = "al2023@v20260903"
  ami_release        = "1.36.3-20260903"

  vpc_cidr = "10.42.0.0/16"
  azs      = slice(sort(data.aws_availability_zones.available.names), 0, min(3, length(data.aws_availability_zones.available.names)))
  tags = {
    Project     = var.cluster_name
    Environment = "poc"
    ManagedBy   = "terraform"
  }
}

data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "zone-type"
    values = ["availability-zone"]
  }

  lifecycle {
    postcondition {
      condition     = length(self.names) >= 3
      error_message = "This POC needs at least three available standard AZs. Choose another AWS Region."
    }
  }
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.7.2"

  name = var.cluster_name
  cidr = local.vpc_cidr
  azs  = local.azs

  private_subnets = [for i in range(3) : cidrsubnet(local.vpc_cidr, 4, i)]
  public_subnets  = [for i in range(3) : cidrsubnet(local.vpc_cidr, 8, i + 48)]
  intra_subnets   = [for i in range(3) : cidrsubnet(local.vpc_cidr, 8, i + 52)]

  enable_dns_hostnames    = true
  enable_dns_support      = true
  map_public_ip_on_launch = false
  enable_nat_gateway      = true
  single_nat_gateway      = var.single_nat_gateway
  one_nat_gateway_per_az  = !var.single_nat_gateway

  enable_flow_log                                 = true
  create_flow_log_cloudwatch_log_group            = true
  create_flow_log_cloudwatch_iam_role             = true
  flow_log_cloudwatch_log_group_retention_in_days = 7

  public_subnet_tags = {
    "kubernetes.io/role/elb" = "1"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = "1"
    "karpenter.sh/discovery"          = var.cluster_name
  }

  tags = local.tags
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.25.0"

  name                = var.cluster_name
  kubernetes_version  = local.kubernetes_version
  authentication_mode = "API"
  enable_irsa         = false

  vpc_id                       = module.vpc.vpc_id
  subnet_ids                   = module.vpc.private_subnets
  control_plane_subnet_ids     = module.vpc.intra_subnets
  endpoint_private_access      = true
  endpoint_public_access       = true
  endpoint_public_access_cidrs = var.api_allowed_cidrs

  enable_cluster_creator_admin_permissions = false
  access_entries = {
    operator = {
      principal_arn = var.cluster_admin_arn
      policy_associations = {
        admin = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster"
          }
        }
      }
    }
  }

  enabled_log_types                      = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
  cloudwatch_log_group_retention_in_days = 7
  create_kms_key                         = true
  enable_kms_key_rotation                = true
  encryption_config                      = { resources = ["secrets"] }

  addons = {
    eks-pod-identity-agent = {
      before_compute = true
      addon_version  = lookup(var.addon_versions, "eks-pod-identity-agent", null)
    }
    vpc-cni = {
      before_compute = true
      addon_version  = lookup(var.addon_versions, "vpc-cni", null)
      pod_identity_association = [{
        role_arn        = aws_iam_role.vpc_cni.arn
        service_account = "aws-node"
      }]
    }
    kube-proxy = {
      addon_version = lookup(var.addon_versions, "kube-proxy", null)
    }
    coredns = {
      addon_version = lookup(var.addon_versions, "coredns", null)
      configuration_values = jsonencode({
        nodeSelector = { "opsfleet.com/node-purpose" = "system" }
        tolerations = [
          { key = "CriticalAddonsOnly", operator = "Exists" },
          { key = "node-role.kubernetes.io/control-plane", effect = "NoSchedule" }
        ]
      })
    }
  }

  eks_managed_node_groups = {
    system = {
      ami_type                   = "AL2023_x86_64_STANDARD"
      ami_release_version        = local.ami_release
      instance_types             = ["m6i.large", "m6a.large", "m7i.large"]
      capacity_type              = "ON_DEMAND"
      min_size                   = 2
      desired_size               = 2
      max_size                   = 3
      iam_role_attach_cni_policy = false

      labels = { "opsfleet.com/node-purpose" = "system" }
      taints = {
        critical = { key = "CriticalAddonsOnly", value = "true", effect = "NO_SCHEDULE" }
      }
      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required"
        http_put_response_hop_limit = 1
      }
      block_device_mappings = {
        root = {
          device_name = "/dev/xvda"
          ebs = {
            volume_type           = "gp3"
            volume_size           = 30
            encrypted             = true
            delete_on_termination = true
          }
        }
      }
      update_config = { max_unavailable = 1 }
    }
  }

  # Only this node SG and private workload subnets receive discovery tags.
  node_security_group_tags = { "karpenter.sh/discovery" = var.cluster_name }
  tags                     = local.tags

  depends_on = [aws_iam_role_policy_attachment.vpc_cni]
}
