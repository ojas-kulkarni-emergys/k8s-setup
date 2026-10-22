from pathlib import Path
import shlex
import tempfile
import unittest
from unittest.mock import patch
import yaml
from pool_dashboard.command_preview import CommandPreview
from pool_dashboard.settings import Settings
from pool_dashboard.app import create_app
from test_dashboard import InProcessClient


class CommandPreviewTests(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name)
        self.settings=Settings(state_dir=self.root/'state', scripts_root=self.root,command_prefix=['k8s'])
        (self.root/'config.yaml').write_text(yaml.safe_dump({'example':{'namespace':'office-models','model':'distilgpt2'}}))
        (self.root/'main.sh').write_text('''dispatch() {
  case "$1" in
    --example) bash "$ROOT/module.sh" "$CONFIG" ;;
    *) return 2 ;;
  esac
}
''')
        self.module=self.root/'module.sh'
        self.module.write_text('''model="$(cfg example.model)"
namespace="$(cfg example.namespace)"
read -r -p 'Worker name: ' worker
k8s kubectl get pods -n "$namespace" -l "model=$model"
k8s get-join-token "$worker" --worker
''')

    def test_routes_come_from_main_and_values_from_yaml(self):
        preview=CommandPreview(self.settings)
        self.assertEqual(preview.routes()[0]['action'],'--example')
        result=preview.preview('--example')
        self.assertEqual(result['question']['key'],'read:module.sh:3')
        result=CommandPreview(self.settings,{'read:module.sh:3':'worker-one'}).preview('--example')
        self.assertTrue(result['complete'],result)
        self.assertEqual(result['steps'][0]['command'],'k8s kubectl get pods -n "office-models" -l "model=distilgpt2"')
        self.assertEqual(result['steps'][1]['command'],'k8s get-join-token "worker-one" --worker')
        self.assertEqual(result['steps'][1]['source'],'module.sh')

    def test_script_edit_is_immediately_reflected(self):
        self.module.write_text('snap services k8s\n')
        self.assertEqual(CommandPreview(self.settings).preview('--example')['steps'][0]['command'],'snap services k8s')
        self.module.write_text('snap stop k8s\n')
        self.assertEqual(CommandPreview(self.settings).preview('--example')['steps'][0]['command'],'snap stop k8s')

    def test_runtime_substitution_is_never_executed(self):
        self.module.write_text('value="$(touch /tmp/never-execute-preview)"\necho "$value"\n')
        with patch('subprocess.run',side_effect=AssertionError('No shell execution')):
            result=CommandPreview(self.settings).preview('--example')
        self.assertFalse(result['complete'])
        self.assertIn('$(touch /tmp/never-execute-preview)',result['question']['label'])

    def test_input_is_shell_quoted(self):
        value='worker"; touch /tmp/never-execute-preview; echo "$(whoami)'
        result=CommandPreview(self.settings,{'read:module.sh:3':value}).preview('--example')
        command=result['steps'][-1]['command']
        # Quoting prevents breaking out of the original argument; dollar syntax
        # is escaped and would be literal in the displayed command.
        self.assertIn('\\"',command)
        self.assertIn('\\$(whoami)',command)
        self.assertEqual(len(shlex.split(command)),4)

    def test_unsupported_loop_stops_instead_of_claiming_complete(self):
        self.module.write_text('for image in a b\ndo\n  echo "$image"\ndone\n')
        result=CommandPreview(self.settings).preview('--example')
        self.assertFalse(result['complete'])
        self.assertIn('manual source review',result['limitation'])

    def test_authenticated_api_and_path_escape(self):
        app=create_app(self.settings,token='test-admin-token')
        client=InProcessClient(app)
        self.assertEqual(client.get('/api/v1/setup/command-routes').status_code,401)
        result=client.post('/api/v1/setup/command-preview',headers={'Authorization':'Bearer test-admin-token'},json={'action':'--example'})
        self.assertEqual(result.status_code,200)
        self.assertEqual(result.headers['cache-control'],'no-store')
        self.module.write_text('source "/tmp/outside-repo.sh"\n')
        result=CommandPreview(self.settings).preview('--example')
        self.assertIn('inside the repository',result['limitation'])

    def test_real_services_submenu_and_cfg_interpolation(self):
        actual=Settings.load()
        preview=CommandPreview(actual)
        question=preview.preview('--services')['question']
        result=CommandPreview(actual,{question['key']:'1'}).preview('--services')
        inputs={question['key']:'1',result['question']['key']:'4'}
        result=CommandPreview(actual,inputs).preview('--services')
        self.assertTrue(result['complete'],result)
        self.assertEqual(len(result['steps']),1)
        self.assertIn('kubectl logs -n "kube-system"',result['steps'][0]['command'])
        self.assertNotIn('$(cfg',result['steps'][0]['command'])

    def test_quoted_heredoc_program_is_not_shell_interpolated(self):
        self.module.write_text('''python3 - "$(cfg example.model)" <<'PYCODE'
print("$literal_python_string")
PYCODE
''')
        result=CommandPreview(self.settings).preview('--example')
        self.assertTrue(result['complete'],result)
        self.assertIn('python3 - "distilgpt2"',result['steps'][0]['command'])
        self.assertIn('$literal_python_string',result['steps'][0]['command'])
