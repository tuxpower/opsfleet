#!/usr/bin/env python3
"""Create private POC inputs from the active AWS identity; preserve existing tfvars."""
import argparse
import ipaddress
import json
import os
from pathlib import Path
import re
import subprocess
import urllib.error
import urllib.request

CLUSTER_ROOT = Path(__file__).resolve().parents[1] / "01-cluster"


def aws_json(*args):
    result = subprocess.run(
        ["aws", *args, "--output", "json", "--no-cli-pager"],
        capture_output=True, text=True, check=False,
    )
    if result.returncode:
        raise RuntimeError(result.stderr.strip())
    return json.loads(result.stdout)


def main():
    argparse.ArgumentParser(description=__doc__).parse_args()
    existing = [p for p in CLUSTER_ROOT.iterdir() if p.is_file() and (
        p.name in ("terraform.tfvars", "terraform.tfvars.json")
        or p.name.endswith((".auto.tfvars", ".auto.tfvars.json"))
    )]
    if existing:
        print("Using existing inputs: " + ", ".join(p.name for p in sorted(existing)))
        return

    identity = aws_json("sts", "get-caller-identity")
    account = identity["Account"]
    if not re.fullmatch(r"[0-9]{12}", account):
        raise RuntimeError("AWS returned an invalid account ID.")
    if identity["Arn"].endswith(":root"):
        raise RuntimeError("Use an IAM role or user for this POC, not the AWS root identity.")
    expected = os.environ.get("POC_ACCOUNT_ID")
    if expected and expected != account:
        raise RuntimeError(f"Expected AWS account {expected}, but the active identity uses {account}.")

    cidr = os.environ.get("POC_API_CIDR")
    if not cidr:
        with urllib.request.urlopen("https://checkip.amazonaws.com", timeout=10) as response:
            cidr = response.read(128).decode().strip() + "/32"
    network = ipaddress.ip_network(cidr, strict=True)
    if network.version != 4 or network.prefixlen < 24:
        raise RuntimeError("POC_API_CIDR must be an IPv4 /24 or narrower, normally your public /32.")

    spot_role = subprocess.run(
        ["aws", "iam", "get-role", "--role-name", "AWSServiceRoleForEC2Spot", "--no-cli-pager"],
        capture_output=True, text=True, check=False,
    )
    if spot_role.returncode and "(NoSuchEntity)" not in spot_role.stderr:
        raise RuntimeError(spot_role.stderr.strip())

    values = {
        "aws_account_id": account,
        "api_allowed_cidrs": [str(network)],
        "region": os.environ.get("POC_REGION", "eu-west-1"),
        "cluster_name": os.environ.get("POC_CLUSTER_NAME", "opsfleet-poc"),
        "create_spot_service_linked_role": bool(spot_role.returncode),
    }
    destination = CLUSTER_ROOT / "terraform.tfvars.json"
    descriptor = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w") as handle:
        json.dump(values, handle, indent=2)
        handle.write("\n")
    print(f"Created private inputs for account {account}, {values['region']}, API CIDR {network}.")
    print("Operator access uses the current IAM user/role, including SSO; review Terraform's plan before applying.")


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, ValueError, OSError, urllib.error.URLError) as error:
        raise SystemExit(f"Configuration failed: {error}") from error
