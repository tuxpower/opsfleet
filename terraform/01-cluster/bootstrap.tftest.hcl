# Plan the real module graph without AWS access. These tests do not deploy a cluster.
mock_provider "aws" {
  mock_data "aws_availability_zones" {
    defaults = { names = ["eu-west-1a", "eu-west-1b", "eu-west-1c"] }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws", dns_suffix = "amazonaws.com" }
  }
  mock_data "aws_region" {
    defaults = { region = "eu-west-1", name = "eu-west-1" }
  }
  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
      arn        = "arn:aws:sts::123456789012:assumed-role/AssessmentSSO/session"
    }
  }
  mock_data "aws_iam_session_context" {
    defaults = { issuer_arn = "arn:aws:iam::123456789012:role/AssessmentSSO" }
  }
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_data "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::123456789012:role/opsfleet-poc-cni" }
  }
  mock_data "aws_eks_addon_version" {
    defaults = { version = "v1.0.0-eksbuild.1" }
  }
}
mock_provider "cloudinit" {}
mock_provider "time" {}
mock_provider "tls" {}
mock_provider "null" {}

variables {
  aws_account_id    = "123456789012"
  api_allowed_cidrs = ["203.0.113.10/32"]
}

run "sso_operator_single_nat" {
  command = plan

  assert {
    condition     = module.eks.access_entries["cluster_creator"].principal_arn == "arn:aws:iam::123456789012:role/AssessmentSSO"
    error_message = "Default operator access must use the permanent IAM role, not its STS session ARN."
  }
  assert {
    condition     = length(module.vpc.natgw_ids) == 1
    error_message = "The default POC should create one NAT gateway."
  }
}

run "explicit_operator_ha_and_image_override" {
  command = plan
  variables {
    cluster_admin_arn  = "arn:aws:iam::123456789012:role/StableOperator"
    single_nat_gateway = false
    ami_alias          = "al2023@latest"
    ami_release        = null
  }

  assert {
    condition     = keys(module.eks.access_entries) == ["operator"]
    error_message = "An explicit operator must replace the caller-derived access entry."
  }
  assert {
    condition     = module.eks.access_entries["operator"].principal_arn == "arn:aws:iam::123456789012:role/StableOperator"
    error_message = "The supplied operator role must receive cluster access."
  }
  assert {
    condition     = length(module.vpc.natgw_ids) == 3
    error_message = "The HA option must create one NAT gateway per AZ."
  }
}
