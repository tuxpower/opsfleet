#!/usr/bin/env bash
# Static checks only. init downloads pinned dependencies; no AWS resources are created.
set -euo pipefail

TERRAFORM_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
terraform fmt -check -recursive "$TERRAFORM_ROOT"

# Sequential validation avoids running several large provider processes at once.
for stage in 01-cluster 02-karpenter 03-nodepools; do
  terraform -chdir="$TERRAFORM_ROOT/$stage" init -backend=false -input=false -lockfile=readonly
  terraform -chdir="$TERRAFORM_ROOT/$stage" validate -no-color
done

kubectl kustomize "$TERRAFORM_ROOT/examples" > /dev/null
python3 - "$TERRAFORM_ROOT/scripts/verify.py" <<'PY'
import ast
import pathlib
import sys

ast.parse(pathlib.Path(sys.argv[1]).read_text())
print("PASS: example manifests render and verification script parses")
PY
