terraform {
  required_version = ">= 1.10, < 2.0"
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.38"
    }
  }
}

data "terraform_remote_state" "cluster" {
  backend = "local"
  config  = { path = "${path.module}/../01-cluster/terraform.tfstate" }
}

locals {
  cluster = data.terraform_remote_state.cluster.outputs.connection
}

provider "kubernetes" {
  host                   = local.cluster.endpoint
  cluster_ca_certificate = base64decode(local.cluster.certificate_authority_data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--region", local.cluster.region, "--cluster-name", local.cluster.name]
  }
}

resource "kubernetes_manifest" "node_class" {
  manifest = {
    apiVersion = "karpenter.k8s.aws/v1"
    kind       = "EC2NodeClass"
    metadata   = { name = "default" }
    spec = {
      amiFamily        = "AL2023"
      amiSelectorTerms = [{ alias = local.cluster.ami_alias }]
      instanceProfile  = local.cluster.instance_profile
      subnetSelectorTerms = [{
        tags = { "karpenter.sh/discovery" = local.cluster.name }
      }]
      securityGroupSelectorTerms = [{
        tags = { "karpenter.sh/discovery" = local.cluster.name }
      }]
      associatePublicIPAddress = false
      metadataOptions = {
        httpEndpoint            = "enabled"
        httpTokens              = "required"
        httpPutResponseHopLimit = 1
      }
      blockDeviceMappings = [{
        deviceName = "/dev/xvda"
        ebs = {
          volumeSize          = "30Gi"
          volumeType          = "gp3"
          encrypted           = true
          deleteOnTermination = true
        }
      }]
      tags = {
        Project     = local.cluster.name
        Environment = "poc"
        ManagedBy   = "karpenter"
      }
    }
  }
}

resource "kubernetes_manifest" "node_pool" {
  for_each = toset(["amd64", "arm64"])

  manifest = {
    apiVersion = "karpenter.sh/v1"
    kind       = "NodePool"
    metadata   = { name = each.value }
    spec = {
      # A neutral multi-architecture workload prefers Graviton when feasible.
      weight = each.value == "arm64" ? 20 : 10
      template = {
        metadata = { labels = { "opsfleet.com/node-purpose" = "workload" } }
        spec = {
          nodeClassRef = {
            group = "karpenter.k8s.aws"
            kind  = "EC2NodeClass"
            name  = kubernetes_manifest.node_class.manifest.metadata.name
          }
          requirements = [
            { key = "kubernetes.io/arch", operator = "In", values = [each.value] },
            { key = "kubernetes.io/os", operator = "In", values = ["linux"] },
            { key = "karpenter.sh/capacity-type", operator = "In", values = ["spot", "on-demand"] },
            { key = "karpenter.k8s.aws/instance-category", operator = "In", values = ["c", "m", "r"] },
            { key = "karpenter.k8s.aws/instance-generation", operator = "Gt", values = ["5"] },
            { key = "karpenter.k8s.aws/instance-cpu", operator = "In", values = ["2", "4", "8"] }
          ]
          expireAfter            = "720h"
          terminationGracePeriod = "5m"
        }
      }
      limits = { cpu = "32", memory = "128Gi" }
      disruption = {
        consolidationPolicy = "WhenEmptyOrUnderutilized"
        consolidateAfter    = "1m"
        budgets             = [{ nodes = "1" }]
      }
    }
  }
}
