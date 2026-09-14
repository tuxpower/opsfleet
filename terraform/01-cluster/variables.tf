variable "aws_account_id" {
  description = "Target AWS account; the provider rejects credentials for a different account."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.aws_account_id))
    error_message = "Supply the 12-digit AWS account ID."
  }
}

variable "cluster_admin_arn" {
  description = "Permanent IAM role/user ARN for the operator running all three stages; not an STS session ARN."
  type        = string

  validation {
    condition     = can(regex("^arn:aws:iam::[0-9]{12}:(role|user)/.+$", var.cluster_admin_arn))
    error_message = "Use an IAM role or user ARN, including its path; do not use an assumed-role session ARN."
  }
}

variable "api_allowed_cidrs" {
  description = "IPv4 egress CIDRs of operators/runners allowed to reach the public EKS API."
  type        = list(string)

  validation {
    condition = length(var.api_allowed_cidrs) > 0 && alltrue([
      for cidr in var.api_allowed_cidrs :
      can(cidrnetmask(cidr)) && try(tonumber(split("/", cidr)[1]) >= 24, false)
    ])
    error_message = "Supply at least one valid IPv4 CIDR, /24 or narrower (normally your public /32)."
  }
}

variable "region" {
  description = "AWS Region with at least three standard availability zones."
  type        = string
  default     = "eu-west-1"
}

variable "cluster_name" {
  description = "Name used for the cluster and its discovery tags."
  type        = string
  default     = "opsfleet-poc"

  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,29}$", var.cluster_name))
    error_message = "Use 3–30 lowercase letters, digits or hyphens, starting with a letter."
  }
}

variable "single_nat_gateway" {
  description = "POC cost saving. Set false for one NAT gateway per AZ."
  type        = bool
  default     = true
}

variable "create_spot_service_linked_role" {
  description = "Set true only if AWSServiceRoleForEC2Spot does not already exist in this account."
  type        = bool
  default     = false
}

variable "addon_versions" {
  description = "Optional tested version pins by addon name; unset addons resolve the latest EKS-compatible build at plan time."
  type        = map(string)
  default     = {}
}
