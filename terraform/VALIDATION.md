# Validation record

**14 September 2026 — local validation, without creating AWS resources.**

This validation round covers code and local checks only. The checks below passed; **no live AWS plan/apply, EC2 launches or teardown were performed.** Local checks cannot establish regional capacity, account quotas, effective IAM permissions or successful node bootstrap.

| Check | Result and scope |
| --- | --- |
| `terraform fmt -check -recursive terraform` | Passed |
| `terraform init -backend=false -input=false -lockfile=readonly` | Passed in all three roots, reusing the committed provider locks |
| `terraform validate -no-color` | Passed in all three roots with Terraform 1.16.2 on Linux amd64 |
| Mocked Terraform plans | Two passed against the real module graph: SSO caller resolves to its permanent IAM role with one NAT; an explicit operator role, three NATs and AMI overrides also plan successfully. AWS responses are mocked |
| Deployment helper tests | Nine passed using fake AWS/Terraform executables: configuration preservation, account/CIDR checks, Spot-role error handling, stage ordering, explicit auto-approval, isolated kubeconfig and stopping on a failed stage |
| Example rendering | `kubectl kustomize terraform/examples` produced one Namespace, two Deployments and two Services with the expected namespace |
| Verification script | Python parsing, CLI help and Bash syntax checks passed; the runtime verifier itself was not run against a cluster |
| Helm values | Evaluated the actual Terraform expressions in an isolated temporary directory with placeholder connection outputs |
| Karpenter controller chart | Downloaded OCI chart 1.14.1; `helm lint` and local `helm template` passed. Rendered two replicas, system-node selection, hostname anti-affinity, Pod Identity service-account name and the configured interruption queue |
| CRD chart and manifests | Downloaded matching CRD chart 1.14.1 and rendered it. Evaluated the actual EC2NodeClass and both NodePool expressions; checked declared fields, required fields and enum values against the v1 CRD schemas. This does not execute Kubernetes CEL or controller validation |
| Multi-architecture image | The pinned BusyBox OCI index was checked against Docker Hub metadata and contains both `linux/amd64` and `linux/arm64` |
| Architecture HLD | Graphviz rendered the editable source to SVG; the rendered layout was visually inspected |

Downloaded chart digests:

```text
karpenter:1.14.1
sha256:91434e00fb102d6ee0d1bd34a4457a32fe01a8fa833fe1a2a37da4f50272079b

karpenter-crd:1.14.1
sha256:c05c566740802506a34f3500b33e2fa3c9254f60469e84e5e294a3bd8adefb9f
```

The packaged controller chart rendered image `public.ecr.aws/karpenter/controller:1.14.1@sha256:445baefaaa689029cc12ac1f659b916b0b82fb14308ce536f8521fcf079116fa`. The demo image index is `docker.io/library/busybox:1.37.0@sha256:9db7b59979c38555a39def84a31fb98b5296952f9e3afd4f6f11f05b07adfab0`.

## Reproduce the standard local checks

From the repository root, with Terraform, kubectl and Python 3 installed:

```bash
bash terraform/scripts/validate.sh
```

This downloads pinned dependencies if necessary, validates the roots sequentially, runs mocked plans and helper tests, and renders the examples. It does not contact the EKS API or apply infrastructure. The extended Helm/CRD field review above was a separate local review.

## Future runtime acceptance

For a future deployment, follow [README.md](README.md) and capture these results before describing the POC as runtime-tested:

| Acceptance condition | Evidence to capture |
| --- | --- |
| EKS and system nodes healthy | EKS status, at least two ready Graviton On-Demand system nodes, healthy CNI/Pod Identity/CoreDNS/kube-proxy |
| Karpenter ready | Two available controller replicas; EC2NodeClass and both NodePools Ready |
| Both architectures provision successfully | `python3 terraform/scripts/verify.py`: ready demo replicas, node architecture/pool labels, no public node IP, and both HTTP responses |
| Actual Spot capacity used | Apply the [Spot-only selectors](OPERATIONS.md#spot-only-acceptance-test), then run `python3 terraform/scripts/verify.py --require-spot` |
| Repeated apply is stable | A new plan in each stage shows no unintended changes; record the resolved EKS add-on versions |
| Cleanup is complete | Follow the [teardown sequence](OPERATIONS.md#teardown); no remaining Karpenter NodeClaims/EC2 instances, then successful controller and cluster destruction |

Record test date, Region, deployed versions and pass/fail outcomes without publishing credentials, kubeconfig, Terraform state or sensitive account output. A Pending Spot-only workload is a capacity/quota diagnostic outcome, not a successful Spot acceptance test. Production SLO, interruption, failover and recovery exercises in the architecture document are proposed future checks and have not been performed by this submission.
