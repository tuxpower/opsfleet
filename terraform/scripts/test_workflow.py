#!/usr/bin/env python3
"""Exercise configuration and deployment orchestration with fake CLIs; no AWS access."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

SCRIPTS = Path(__file__).resolve().parent
FAKE_CLI = r'''
import json, os, pathlib, sys
args = sys.argv[1:]
tool = pathlib.Path(sys.argv[0]).name
with open(os.environ['FAKE_LOG'], 'a') as log:
    log.write(json.dumps([tool, *args]) + '\n')
if tool == 'aws':
    if args[:2] == ['sts', 'get-caller-identity']:
        print(json.dumps({'Account': '111122223333', 'Arn': 'arn:aws:sts::111122223333:assumed-role/TestSSO/session'}))
    elif args[:2] == ['iam', 'get-role']:
        status = os.environ.get('FAKE_SPOT_ROLE', 'present')
        if status != 'present':
            code = 'NoSuchEntity' if status == 'missing' else 'AccessDenied'
            print(f'An error occurred ({code}) when calling GetRole', file=sys.stderr)
            sys.exit(254)
        print('{}')
    elif args[:2] == ['eks', 'update-kubeconfig']:
        print('Updated isolated kubeconfig')
    else:
        sys.exit('Unexpected AWS command')
elif tool == 'terraform':
    if 'apply' in args and os.environ.get('FAKE_FAIL_STAGE', '<none>') in args[0]:
        sys.exit('Simulated stage failure')
    if 'output' in args:
        print('opsfleet-test' if args[-1] == 'cluster_name' else 'eu-west-1')
'''


class WorkflowTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='opsfleet-workflow-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.tf = self.root / 'terraform'
        (self.tf / 'scripts').mkdir(parents=True)
        for stage in ('01-cluster', '02-karpenter', '03-nodepools'):
            (self.tf / stage).mkdir()
        for script in ('configure.py', 'deploy.sh'):
            shutil.copy2(SCRIPTS / script, self.tf / 'scripts' / script)
        binaries = self.root / 'bin'
        binaries.mkdir()
        for tool in ('aws', 'terraform', 'kubectl'):
            path = binaries / tool
            path.write_text(f'#!{sys.executable}\n' + FAKE_CLI)
            path.chmod(0o755)
        self.log = self.root / 'calls.jsonl'
        self.env = {k: v for k, v in os.environ.items()
                    if not k.startswith(('POC_', 'FAKE_', 'TF_VAR_', 'TF_CLI_ARGS'))}
        self.env.update(PATH=str(binaries) + os.pathsep + os.environ['PATH'],
                        FAKE_LOG=str(self.log), POC_API_CIDR='203.0.113.10/32')
        self.config = self.tf / '01-cluster' / 'terraform.tfvars.json'

    def run_script(self, name, *args):
        executable = sys.executable if name.endswith('.py') else 'bash'
        return subprocess.run([executable, str(self.tf / 'scripts' / name), *args],
                              env=self.env, text=True, capture_output=True)

    def calls(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def test_config_detects_identity_and_preserves_inputs(self):
        result = self.run_script('configure.py')
        self.assertEqual(result.returncode, 0, result.stderr)
        config = json.loads(self.config.read_text())
        self.assertEqual(config['aws_account_id'], '111122223333')
        self.assertEqual(config['api_allowed_cidrs'], ['203.0.113.10/32'])
        self.assertFalse(config['create_spot_service_linked_role'])
        self.assertNotIn('cluster_admin_arn', config)
        self.assertEqual(self.config.stat().st_mode & 0o777, 0o600)
        previous = self.config.read_bytes()
        count = len(self.calls())
        self.env['POC_API_CIDR'] = '198.51.100.1/32'
        self.assertEqual(self.run_script('configure.py').returncode, 0)
        self.assertEqual(self.config.read_bytes(), previous)
        self.assertEqual(len(self.calls()), count)

    def test_manual_inputs_are_not_overwritten(self):
        path = self.tf / '01-cluster' / 'terraform.tfvars'
        path.write_text('region = "eu-west-1"\n')
        self.assertEqual(self.run_script('configure.py').returncode, 0)
        self.assertFalse(self.config.exists())
        self.assertFalse(self.calls())

    def test_wrong_account_stops_before_terraform(self):
        self.env['POC_ACCOUNT_ID'] = '444455556666'
        result = self.run_script('deploy.sh', '--yes')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Expected AWS account', result.stderr)
        self.assertFalse(self.config.exists())
        self.assertFalse(any(call[0] == 'terraform' for call in self.calls()))

    def test_worldwide_cidr_is_rejected(self):
        self.env['POC_API_CIDR'] = '0.0.0.0/0'
        self.assertNotEqual(self.run_script('configure.py').returncode, 0)
        self.assertFalse(self.config.exists())

    def test_missing_spot_role_is_distinct_from_access_denied(self):
        self.env['FAKE_SPOT_ROLE'] = 'denied'
        self.assertNotEqual(self.run_script('configure.py').returncode, 0)
        self.assertFalse(self.config.exists())
        self.env['FAKE_SPOT_ROLE'] = 'missing'
        self.assertEqual(self.run_script('configure.py').returncode, 0)
        self.assertTrue(json.loads(self.config.read_text())['create_spot_service_linked_role'])

    def test_apply_order_and_explicit_auto_approval(self):
        result = self.run_script('deploy.sh', '--yes')
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.calls()
        applies = [call for call in calls if call[0] == 'terraform' and 'apply' in call]
        self.assertEqual([Path(call[1].split('=', 1)[1]).name for call in applies],
                         ['01-cluster', '02-karpenter', '03-nodepools'])
        self.assertTrue(all('-auto-approve' in call for call in applies))
        kubeconfig = next(call for call in calls if call[:3] == ['aws', 'eks', 'update-kubeconfig'])
        self.assertEqual(kubeconfig[kubeconfig.index('--kubeconfig') + 1], str(self.tf / 'kubeconfig'))
        self.assertLess(calls.index(applies[0]), calls.index(kubeconfig))
        self.assertLess(calls.index(kubeconfig), calls.index(applies[1]))

    def test_default_keeps_terraform_approval(self):
        self.assertEqual(self.run_script('deploy.sh').returncode, 0)
        applies = [call for call in self.calls() if call[0] == 'terraform' and 'apply' in call]
        self.assertTrue(applies)
        self.assertFalse(any('-auto-approve' in call for call in applies))

    def test_stage_failure_does_not_apply_later_stages(self):
        self.env['FAKE_FAIL_STAGE'] = '02-karpenter'
        self.assertNotEqual(self.run_script('deploy.sh', '--yes').returncode, 0)
        self.assertFalse(any('03-nodepools' in ' '.join(call) for call in self.calls()))

    def test_help_and_invalid_arguments_do_not_call_aws(self):
        self.assertEqual(self.run_script('deploy.sh', '--help').returncode, 0)
        self.assertNotEqual(self.run_script('deploy.sh', '--unknown').returncode, 0)
        self.assertFalse(self.calls())


if __name__ == '__main__':
    unittest.main()
