#!/usr/bin/env bash
# Create the cluster, install Karpenter, then create its NodePools.
set -euo pipefail

usage() {
  cat <<'HELP'
Usage: deploy.sh [--yes]

Uses the active AWS credentials and applies all three Terraform roots in order.
Existing tfvars are preserved. Otherwise it creates private inputs using the
current account, IAM identity, public /32 and Spot service-linked role status.
Terraform asks for approval at each stage; --yes explicitly skips those prompts.

Optional environment variables for initial configuration:
  AWS_PROFILE        AWS CLI/Terraform credential profile
  POC_ACCOUNT_ID     Expected account ID; reject a different active account
  POC_REGION         AWS Region (default: eu-west-1)
  POC_CLUSTER_NAME   Cluster name (default: opsfleet-poc)
  POC_API_CIDR       Explicit public IPv4 CIDR instead of automatic /32 detection

Creates billable AWS resources. Follow OPERATIONS.md to remove them after testing.
HELP
}

apply_args=()
if [[ $# -gt 1 ]]; then usage >&2; exit 2; fi
case "${1:-}" in
  --help|-h) usage; exit 0 ;;
  --yes) apply_args=(-auto-approve) ;;
  "") ;;
  *) usage >&2; exit 2 ;;
esac

for tool in terraform aws kubectl python3; do
  command -v "$tool" >/dev/null || { printf 'Missing prerequisite: %s\n' "$tool" >&2; exit 1; }
done

TERRAFORM_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
python3 "$TERRAFORM_ROOT/scripts/configure.py"

for stage in 01-cluster 02-karpenter 03-nodepools; do
  terraform -chdir="$TERRAFORM_ROOT/$stage" init -input=false -lockfile=readonly
  terraform -chdir="$TERRAFORM_ROOT/$stage" apply "${apply_args[@]}"
  if [[ "$stage" == 01-cluster ]]; then
    POC_CLUSTER="$(terraform -chdir="$TERRAFORM_ROOT/$stage" output -raw cluster_name)"
    POC_REGION="$(terraform -chdir="$TERRAFORM_ROOT/$stage" output -raw region)"
    aws eks update-kubeconfig --region "$POC_REGION" --name "$POC_CLUSTER" \
      --alias "$POC_CLUSTER" --kubeconfig "$TERRAFORM_ROOT/kubeconfig"
  fi
done

printf 'Deployment complete. For the examples, export KUBECONFIG=%q\n' "$TERRAFORM_ROOT/kubeconfig"
