# POC operations

Commands assume the repository root and the same AWS identity used during deployment. Recover the context variables in a new terminal with:

```bash
export POC_CLUSTER="$(terraform -chdir=terraform/01-cluster output -raw cluster_name)"
export POC_REGION="$(terraform -chdir=terraform/01-cluster output -raw region)"
```

## Preflight

Before creating resources, confirm the target identity, EKS versions, AZs and service-linked role:

```bash
aws sts get-caller-identity
aws eks describe-cluster-versions --region eu-west-1 \
  --query 'clusterVersions[?status==`STANDARD_SUPPORT`].[clusterVersion,releaseDate]' --output table
aws ec2 describe-availability-zones --region eu-west-1 \
  --filters Name=zone-type,Values=availability-zone --query 'AvailabilityZones[].ZoneName'
aws iam get-role --role-name AWSServiceRoleForEC2Spot --query Role.Arn
aws ssm get-parameter --region eu-west-1 \
  --name /aws/service/eks/optimized-ami/1.36/amazon-linux-2023/x86_64/standard/recommended/release_version \
  --query Parameter.Value --output text
aws ec2 describe-images --region eu-west-1 --owners amazon \
  --filters 'Name=name,Values=amazon-eks-node-al2023-*-standard-1.36-v20260903' \
  --query 'Images[].[Name,Architecture,ImageId]' --output table
```

The SSM command shows the current recommended system-node release; the EC2 query checks the **pinned** release for both architectures. A newer SSM result is not a reason to change pins blindly. If the Spot role lookup returns `NoSuchEntity`, enable its creation in `terraform.tfvars`; an access-denied error is not evidence that the role is missing. Coordinate this account-wide role with the account owner.

Check Service Quotas for EC2 Standard On-Demand vCPUs (`L-1216C47A`) and Standard Spot vCPUs (`L-34B43A08`), VPCs, Elastic IPs and NAT gateways. A fresh account can have insufficient Spot quota. The initial system group needs four On-Demand vCPUs; the demos typically need at least one small workload node per architecture. Capacity availability is separate from quotas.

```bash
aws service-quotas get-service-quota --region eu-west-1 \
  --service-code ec2 --quota-code L-1216C47A --query Quota.Value
aws service-quotas get-service-quota --region eu-west-1 \
  --service-code ec2 --quota-code L-34B43A08 --query Quota.Value
```

## Spot-only acceptance test

The default NodePools accept both capacity types. Karpenter prioritizes Spot within a compatible pool and falls back when offerings are unavailable; existing suitable On-Demand nodes can also accept Pods. [Karpenter's capacity-type scheduling documentation](https://karpenter.sh/docs/concepts/nodepools/) describes this behavior. Successful ARM/x86 scheduling alone does not prove Spot was used.

To require Spot for **both** demos, add a hard capacity selector:

```bash
kubectl --context "$POC_CLUSTER" -n architecture-demo patch deployment hello-amd64 \
  --type=merge -p '{"spec":{"template":{"spec":{"nodeSelector":{"karpenter.sh/capacity-type":"spot"}}}}}'
kubectl --context "$POC_CLUSTER" -n architecture-demo patch deployment hello-arm64 \
  --type=merge -p '{"spec":{"template":{"spec":{"nodeSelector":{"karpenter.sh/capacity-type":"spot"}}}}}'
python3 terraform/scripts/verify.py --require-spot
```

This test may remain Pending if quota or Spot capacity is unavailable. That is intentional: a hard Spot selector forbids On-Demand fallback. Restore the defaults by removing the extra selector:

```bash
kubectl --context "$POC_CLUSTER" -n architecture-demo patch deployment hello-amd64 \
  --type=merge -p '{"spec":{"template":{"spec":{"nodeSelector":{"karpenter.sh/capacity-type":null}}}}}'
kubectl --context "$POC_CLUSTER" -n architecture-demo patch deployment hello-arm64 \
  --type=merge -p '{"spec":{"template":{"spec":{"nodeSelector":{"karpenter.sh/capacity-type":null}}}}}'
```

For an On-Demand-only workload, use the same capacity selector with `on-demand`. Both workload pools diversify across c/m/r families, generations newer than 5, 2/4/8-vCPU sizes and three AZs. Avoid narrowing to a single instance type. ARM instances matching these filters are Graviton. A five-minute termination grace period bounds normal draining; Spot's interruption deadline can be shorter, so it is not a five-minute availability guarantee. EventBridge/SQS feed interruption notices to Karpenter. NodePool budgets constrain voluntary disruption and cannot prevent involuntary Spot loss. See [Karpenter disruption semantics](https://karpenter.sh/docs/concepts/disruption/).

The examples demonstrate CPU placement and intentionally have no availability guarantees or PodDisruptionBudgets. Production services need replicas across nodes/AZs, graceful shutdown, tested PDBs and suitable On-Demand capacity.

## Troubleshooting

```bash
kubectl --context "$POC_CLUSTER" get ec2nodeclasses,nodepools,nodeclaims
kubectl --context "$POC_CLUSTER" describe ec2nodeclass default
kubectl --context "$POC_CLUSTER" describe nodepool arm64
kubectl --context "$POC_CLUSTER" -n architecture-demo describe pods
kubectl --context "$POC_CLUSTER" -n architecture-demo get events --sort-by=.lastTimestamp
kubectl --context "$POC_CLUSTER" -n kube-system logs \
  -l app.kubernetes.io/name=karpenter -c controller --tail=100 --prefix
```

| Symptom | Check |
| --- | --- |
| API timeout | Current public egress CIDR, API allowlist, VPN/firewall and correct Region/context |
| Unauthorized | Permanent IAM principal in the EKS access entry; active AWS profile/session for the CLI exec credential plugin |
| No matching CRD at stage 3 plan | Stage 2 must have completed successfully; check CRDs and controller health |
| NodeClass not Ready | Discovery tags, pinned AMIs in the Region, instance profile and controller IAM permissions |
| Pods Pending / no NodeClaims | Requests, selectors, taints, NodePool limits and controller logs |
| EC2 launch errors | Spot service-linked role, vCPU quotas, AZ offerings and account restrictions |
| Nodes fail to join | Private EKS endpoint routing/security groups, EKS node access entry, Pod Identity agent and CNI IAM |
| ImagePullBackOff | NAT/internet egress, registry availability/rate limits and image architecture |

Node IMDS requires v2 with a hop limit of one. Application pods obtain AWS permissions through their own Pod Identity association, not through the node role. Host-network pods are a different trust boundary. The POC enables EKS control-plane logs and VPC flow logs for seven days; it does not install a complete application observability stack.

## Teardown

Remove applications first, then NodePools while the controller, cluster, IAM and network still exist. Do not uninstall Karpenter or delete its CRDs first: this can strand finalizers and EC2 instances.

```bash
kubectl --context "$POC_CLUSTER" delete -k terraform/examples --ignore-not-found
terraform -chdir=terraform/03-nodepools destroy
kubectl --context "$POC_CLUSTER" get nodeclaims
kubectl --context "$POC_CLUSTER" get nodes -l karpenter.sh/nodepool
# If NodeClaims still exist, wait for their deletion before continuing:
# kubectl --context "$POC_CLUSTER" wait --for=delete nodeclaims --all --timeout=10m
```

Confirm **no NodeClaims or Karpenter-managed nodes remain**, and check that tagged EC2 instances have terminated:

```bash
aws ec2 describe-instances --region "$POC_REGION" \
  --filters "Name=tag:karpenter.sh/nodepool,Values=amd64,arm64" \
    "Name=tag:eks:eks-cluster-name,Values=$POC_CLUSTER" \
    'Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down' \
  --query 'Reservations[].Instances[].[InstanceId,State.Name]' --output table

terraform -chdir=terraform/02-karpenter destroy
terraform -chdir=terraform/01-cluster destroy
```

If the optional Spot service-linked role has since become shared, retain it: before stage 1 destruction, remove **only** `aws_iam_service_linked_role.spot[0]` from this Terraform state with `terraform -chdir=terraform/01-cluster state rm 'aws_iam_service_linked_role.spot[0]'`. This deliberately leaves the account-wide IAM role in AWS; it has no running compute cost. Do not remove state for the other resources as a substitute for destroying them.

If deletion stalls, inspect controller logs, finalizers and EC2 state while the controller is still available. Do not force-remove finalizers as a routine fix. User-created LoadBalancers, volumes and other extra resources must also be cleaned up before deleting the VPC. Check the billing/resource inventory after teardown; KMS key deletion uses a waiting period.

## State and team use

Local state keeps the assessment self-contained; a single operator must retain all three state files. For a shared environment, bootstrap a private S3 bucket with versioning, encryption and tightly scoped IAM outside these roots. Add an S3 backend to each stage, using separate keys such as `poc/cluster.tfstate`, `poc/karpenter.tfstate` and `poc/nodepools.tfstate`, with `use_lockfile = true`. Run `terraform init -migrate-state` for each root and change both `terraform_remote_state.cluster` blocks from `local` to `s3` with the cluster state's bucket/key/Region. Back up state before migrating.

S3 lockfiles require Terraform >=1.10. Grant the documented object and lockfile permissions; a reader of `terraform_remote_state` can access the underlying state, so keep access limited to infrastructure operators. See [Terraform's S3 backend documentation](https://developer.hashicorp.com/terraform/language/backend/s3). Use separate accounts, keys and deployment roles per environment. Keep AWS credentials in SSO/OIDC sessions rather than backend configuration or tfvars.

## Upgrades

Review the [Karpenter upgrade guide](https://karpenter.sh/docs/upgrading/upgrade-guide/) and compatibility matrix, then test changes in a disposable/non-production cluster. Update Kubernetes, compatible Karpenter CRDs/controller, AMI alias, managed-node AMI release and the example Pod Security version label coherently. If an upgrade requires a newer controller before upgrading EKS, upgrade the existing CRDs/controller first; the initial creation order is not a universal upgrade order.

The CRD chart is managed separately because Helm does not automatically upgrade CRDs placed only in a chart's `crds/` directory. Review CRD conversion/storage-version changes and the `03-nodepools` plan. AMI changes can trigger Karpenter drift replacement: validate capacity headroom, disruption budgets and application PDBs. Update provider locks deliberately with `terraform init -upgrade`, review diffs and commit them.

After runtime testing, capture `terraform -chdir=terraform/01-cluster output -json addon_versions` and set the map in your private tfvars. Confirm both CPU architectures, Spot behavior, upgrade/drain behavior and cleanup. Record actual results in [VALIDATION.md](VALIDATION.md).
