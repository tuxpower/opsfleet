# EKS with Karpenter, Graviton and Spot

Builds a dedicated three-AZ VPC, EKS **1.36**, two On-Demand **Graviton system nodes**, and Karpenter **1.14.1**. Separate `amd64` and `arm64` workload pools prefer Spot and allow On-Demand fallback. Workers are private; the public Kubernetes API is restricted to your egress CIDR. IAM uses EKS Pod Identity.

Terraform runs in three stages: `01-cluster/` creates AWS infrastructure, `02-karpenter/` installs the controller and CRDs, and `03-nodepools/` creates the pools. Separate stages let Terraform discover the cluster and CRD schemas before planning resources that need them.

## Deploy

Install Terraform >=1.10 and <2.0, AWS CLI v2, kubectl (prefer 1.36), Bash and Python 3. Authenticate an AWS profile with EKS, VPC/EC2, IAM/PassRole, KMS, Logs, SQS and EventBridge provisioning permissions. Use an assessment account with sufficient On-Demand and Spot quotas.

From the repository root:

```bash
export AWS_PROFILE=assessment  # Replace with your configured profile.
bash terraform/scripts/deploy.sh
```

The helper detects your account, public IPv4 `/32` and Spot-role status, writes ignored private inputs, then applies all three stages in order. Terraform prompts before each apply; `--yes` skips these prompts. Existing tfvars are preserved. SSO/assumed-role sessions work without manually converting their ARN. Set `POC_API_CIDR` if the detected address differs from your EKS API egress; other options are in `deploy.sh --help`.

The default Region is `eu-west-1`. Dated AMIs and provider versions are pinned; `ami_alias` and `ami_release` allow explicit overrides. See [operations](OPERATIONS.md) for version sources, manual deployment, permissions and configuration. EKS, NAT and nodes incur charges while running; delete the POC after testing.

## Run on x86 or Graviton

```bash
export KUBECONFIG="$PWD/terraform/kubeconfig"
kubectl apply -k terraform/examples
python3 terraform/scripts/verify.py
kubectl get nodes -L kubernetes.io/arch,karpenter.sh/capacity-type,karpenter.sh/nodepool
```

The examples use one digest-pinned image supporting both architectures. The verifier checks system nodes, both workload architectures and HTTP responses (`architecture=x86_64` / `architecture=aarch64`). To require Spot, follow the [Spot-only test](OPERATIONS.md#spot-only-acceptance-test) and run the verifier with `--require-spot`.

For a specific CPU, put this under a Deployment's `spec.template.spec` (or a Pod's `spec`):

```yaml
nodeSelector:
  kubernetes.io/arch: arm64  # amd64 for x86; arm64 for Graviton
  opsfleet.com/node-purpose: workload
```

For a multi-architecture image that **prefers Graviton and can fall back to x86**, use:

```yaml
nodeSelector:
  opsfleet.com/node-purpose: workload
affinity:
  nodeAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        preference:
          matchExpressions:
            - key: kubernetes.io/arch
              operator: In
              values: [arm64]
```

Declare CPU/memory requests. A soft preference permits x86; it does not guarantee the cheapest placement. An architecture selector cannot make an x86-only image run on ARM.

## Teardown

Keep Karpenter running until its nodes are gone:

```bash
kubectl delete -k terraform/examples --ignore-not-found
terraform -chdir=terraform/03-nodepools destroy
kubectl get nodeclaims
```

Once no NodeClaims or Karpenter EC2 instances remain, continue:

```bash
terraform -chdir=terraform/02-karpenter destroy
terraform -chdir=terraform/01-cluster destroy
```

[Operations](OPERATIONS.md#teardown) includes the EC2 check and recovery guidance. [Validation](VALIDATION.md) records checks performed. [Architecture](../architecture/README.md) covers Innovate Inc.'s production design.
