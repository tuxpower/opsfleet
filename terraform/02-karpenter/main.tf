terraform {
  required_version = ">= 1.10, < 2.0"
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
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

provider "helm" {
  kubernetes = {
    host                   = local.cluster.endpoint
    cluster_ca_certificate = base64decode(local.cluster.certificate_authority_data)
    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--region", local.cluster.region, "--cluster-name", local.cluster.name]
    }
  }
}

# Manage CRDs explicitly so future chart upgrades also upgrade their schemas.
resource "helm_release" "crds" {
  name       = "karpenter-crd"
  namespace  = "kube-system"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter-crd"
  version    = local.cluster.karpenter_version
  wait       = true
  timeout    = 600
}

resource "helm_release" "karpenter" {
  name       = "karpenter"
  namespace  = "kube-system"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  version    = local.cluster.karpenter_version
  skip_crds  = true
  wait       = true
  atomic     = true
  timeout    = 600

  values = [yamlencode({
    replicas       = 2
    serviceAccount = { name = "karpenter" }
    nodeSelector   = { "opsfleet.com/node-purpose" = "system" }
    tolerations    = [{ key = "CriticalAddonsOnly", operator = "Exists" }]
    dnsPolicy      = "Default"
    settings = {
      clusterName       = local.cluster.name
      clusterEndpoint   = local.cluster.endpoint
      interruptionQueue = local.cluster.interruption_queue
    }
    controller = {
      resources = {
        requests = { cpu = "500m", memory = "1Gi" }
        limits   = { memory = "1Gi" }
      }
    }
  })]

  depends_on = [helm_release.crds]
}

output "karpenter_version" {
  description = "Installed Karpenter controller and CRD chart version."
  value       = helm_release.karpenter.version
}
