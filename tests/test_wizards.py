"""Offline regression checks. No host services or cluster resources are changed."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = '\n'.join((ROOT / 'k8s/node/llm-d' / name).read_text() for name in ('config.sh','workloads.sh','deploy.sh'))
FUNCTIONS = SOURCE[SOURCE.index('workload_action() {'):SOURCE.index('port_forward_service() {')]

class WizardTests(unittest.TestCase):
    def test_shell_syntax(self):
        for path in list(ROOT.glob('*.sh')) + list((ROOT / 'k8s').rglob('*.sh')) + list((ROOT / 'vpn').glob('*/*.sh')):
            subprocess.run(['bash', '-n', str(path)], check=True)

    def test_lifecycle(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            state = root / 'state.json'
            def deployment(name, image, replicas):
                return {'metadata': {'name': name}, 'spec': {'replicas': replicas, 'template': {'spec': {'containers': [{'image': image}]}}}}
            state.write_text(json.dumps({'items': [deployment('model-one', 'vllm/server', 3), deployment('router', 'router/server', 2), deployment('unrelated', 'nginx', 1)]}))
            mock = root / 'kubectl'
            mock.write_text('''#!/usr/bin/env python3
import json,os,sys
p=os.environ['STATE']; d=json.load(open(p)); a=sys.argv[1:]
if a[0]=='get': print(json.dumps(d)); sys.exit()
x=next(x for x in d['items'] if x['metadata']['name']==a[2])
if a[0]=='annotate':
    annotations=x['metadata'].setdefault('annotations',{})
    key='llm-d-router-wizard/original-replicas'
    value=next(t for t in a if t.startswith(key))
    if value.endswith('-'): annotations.pop(key,None)
    else: annotations[key]=value.split('=',1)[1]
elif a[0]=='scale': x['spec']['replicas']=int(next(t.split('=')[1] for t in a if t.startswith('--replicas=')))
elif a[0]=='delete': d['items'].remove(x)
json.dump(d,open(p,'w'))
''')
            mock.chmod(0o755)
            def run(action, answer):
                proc = subprocess.run(['bash', '-c', 'set -Eeuo pipefail\nNAMESPACE=test\nKUBECTL=("$MOCK")\n' + FUNCTIONS + '\n' + action], input=answer, text=True, capture_output=True, env={**os.environ, 'MOCK': str(mock), 'STATE': str(state)})
                self.assertEqual(proc.returncode, 0, proc.stderr)
                return proc.stdout
            run('stop_llmd', '1,1\ny\n')
            data=json.loads(state.read_text())['items']
            self.assertEqual(data[0]['spec']['replicas'], 0)
            self.assertEqual(data[0]['metadata']['annotations']['llm-d-router-wizard/original-replicas'], '3')
            run('stop_llmd', '1\ny\n')
            run('start_model_deployments', 'a\ny\n')
            data=json.loads(state.read_text())['items']
            self.assertEqual(data[0]['spec']['replicas'], 3)
            self.assertEqual(data[1]['spec']['replicas'], 2)
            run('start_model_deployments', 'a\ny\n')
            self.assertEqual(json.loads(state.read_text())['items'][0]['spec']['replicas'], 3)
            run('delete_model_deployments', '1\ny\n')
            self.assertIn('No matching', run('delete_model_deployments', ''))
            self.assertEqual([d['metadata']['name'] for d in json.loads(state.read_text())['items']], ['router', 'unrelated'])

    def test_unit_generation(self):
        code = SOURCE.split("<<'PYUNIT'\n", 1)[1].split('\nPYUNIT', 1)[0]
        with tempfile.TemporaryDirectory() as temp:
            unit=Path(temp)/'test.service'
            subprocess.run(['python3', '-', str(unit), 'test.service', '/snap/bin/k8s', 'test', 'model', '8000:8000'], input=code, text=True, check=True)
            text=unit.read_text()
            for expected in ('Restart=always', 'WantedBy=multi-user.target', '"service/model"', 'StandardError=journal'):
                self.assertIn(expected, text)
            subprocess.run(['systemd-analyze', 'verify', str(unit)], check=True, capture_output=True)

if __name__ == '__main__':
    unittest.main()
