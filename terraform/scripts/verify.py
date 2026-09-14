#!/usr/bin/env python3
"""Verify an already deployed POC. Does not apply infrastructure or workloads."""
import argparse
import json
import os
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if (ROOT / "kubeconfig").is_file():
    os.environ.setdefault("KUBECONFIG", str(ROOT / "kubeconfig"))
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--require-spot", action="store_true",
                    help="Fail unless every demo pod runs on a Spot node.")
args = parser.parse_args()


def command(*args):
    return subprocess.check_output(args, text=True).strip()


def tf_output(name):
    return command("terraform", f"-chdir={ROOT / '01-cluster'}", "output", "-raw", name)


context = tf_output("cluster_name")
print(f"Checking kubeconfig context: {context}", flush=True)


def kubectl(*args):
    return command("kubectl", "--context", context, *args)


def check(condition, message):
    if not condition:
        raise SystemExit(f"FAIL: {message}")


kubectl("wait", "--for=condition=Ready", "ec2nodeclass/default", "--timeout=300s")
for arch in ("amd64", "arm64"):
    kubectl("wait", "--for=condition=Ready", f"nodepool/{arch}", "--timeout=300s")
    kubectl("-n", "architecture-demo", "rollout", "status",
            f"deployment/hello-{arch}", "--timeout=600s")

controller = json.loads(kubectl("-n", "kube-system", "get", "deployment", "karpenter", "-o", "json"))
check(controller.get("status", {}).get("readyReplicas", 0) >= 2, "two Karpenter replicas must be ready")
nodes = {node["metadata"]["name"]: node
         for node in json.loads(kubectl("get", "nodes", "-o", "json"))["items"]}
system_nodes = [node for node in nodes.values()
                if node["metadata"]["labels"].get("opsfleet.com/node-purpose") == "system"
                and not node["metadata"].get("deletionTimestamp")]
check(len(system_nodes) >= 2, "at least two system nodes must exist")
for node in system_nodes:
    labels = node["metadata"]["labels"]
    check(labels.get("kubernetes.io/arch") == "arm64", "system nodes must use Graviton")
    check(labels.get("eks.amazonaws.com/capacityType") == "ON_DEMAND",
          "system nodes must use On-Demand capacity")
    check(any(c["type"] == "Ready" and c["status"] == "True"
              for c in node.get("status", {}).get("conditions", [])),
          "system nodes must be ready")
print(f"PASS: {len(system_nodes)} ready Graviton On-Demand system nodes")

for arch, machine in (("amd64", "x86_64"), ("arm64", "aarch64")):
    pods = json.loads(kubectl("-n", "architecture-demo", "get", "pods",
                            "-l", f"app=hello-{arch}", "-o", "json"))["items"]
    active = [pod for pod in pods if not pod["metadata"].get("deletionTimestamp")]
    check(len(active) >= 2, f"at least two {arch} demo replicas must exist")
    for pod in active:
        check(any(c["type"] == "Ready" and c["status"] == "True"
                  for c in pod.get("status", {}).get("conditions", [])),
              f"{pod['metadata']['name']} must be ready")
        node = nodes[pod["spec"]["nodeName"]]
        labels = node["metadata"]["labels"]
        check(labels.get("kubernetes.io/arch") == arch, f"{arch} pod must use the correct CPU")
        check(labels.get("karpenter.sh/nodepool") == arch, f"{arch} pod must use a Karpenter node")
        capacity = labels.get("karpenter.sh/capacity-type")
        check(capacity in ("spot", "on-demand"), "node must report a supported capacity type")
        if args.require_spot:
            check(capacity == "spot", f"{arch} demo must run on Spot for this acceptance test")
        check(not any(a["type"] == "ExternalIP" for a in node["status"].get("addresses", [])),
              "worker node must not have a public IP")
        print(f"PASS: {pod['metadata']['name']} -> {node['metadata']['name']} "
              f"({arch}, {capacity}, {labels.get('node.kubernetes.io/instance-type')})")
    body = kubectl("-n", "architecture-demo", "exec", f"deployment/hello-{arch}", "--",
                   "wget", "-qO-", f"http://hello-{arch}")
    check(body == f"architecture={machine}", f"{arch} HTTP response must report {machine}")
    print(f"PASS: hello-{arch} Service returns {body}")

print("PASS: controller, node pools, scheduling and both HTTP Services")
print("Spot is capacity-dependent; use the README's Spot-only test to require Spot.")
