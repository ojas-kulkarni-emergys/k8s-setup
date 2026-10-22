import json
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from pool_dashboard.app import create_app
from pool_dashboard.models import JoinRequest
from pool_dashboard.settings import Settings
from test_dashboard import InProcessClient


class RemoteTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.calls = []
        self.settings = Settings(state_dir=Path(self.tmp.name), scripts_root=Path('/tmp'), command_prefix=['k8s'],
                                 remote_execution_enabled=True, ssh_targets={'worker1': {
                                     'host':'10.210.0.2', 'user':'ojas', 'identity_file':'/tmp/test-key',
                                     'known_hosts_file':'/tmp/test-known-hosts'}})
        def cluster_runner(command, **kwargs):
            return subprocess.CompletedProcess(command, 0, stdout=json.dumps({'items':[]}))
        self.app = create_app(self.settings, runner=cluster_runner, token='test-admin-token')
        self.remote = self.app.state.remote
        def ssh_runner(command, **kwargs):
            self.calls.append((command, kwargs))
            return subprocess.CompletedProcess(command, 0, stdout='OK secret-token\n')
        self.remote.runner = ssh_runner
        self.client = InProcessClient(self.app)
        self.headers = {'Authorization':'Bearer test-admin-token'}
        self.body = {'node_name':'worker1','address':'10.210.0.2','token':'secret-token'}

    def test_authentication_and_disabled_default(self):
        self.assertEqual(self.client.get('/api/v1/remote/targets').status_code,401)
        self.settings.remote_execution_enabled=False
        result=self.client.post('/api/v1/remote/targets/worker1/check',headers=self.headers)
        self.assertEqual(result.status_code,409)
        self.assertEqual(self.calls,[])

    def test_allowlist_and_address_guard(self):
        result=self.client.post('/api/v1/remote/targets/unknown/check',headers=self.headers)
        self.assertEqual(result.status_code,404)
        result=self.client.post('/api/v1/remote/targets/worker1/join',headers=self.headers,
                                json={**self.body,'address':'10.210.0.3'})
        self.assertEqual(result.status_code,422)
        self.assertEqual(self.calls,[])

    def test_registered_control_plane_is_rejected(self):
        with patch.object(self.app.state.cluster,'nodes',return_value=[{'name':'control','addresses':[{'address':'10.210.0.2'}]}]):
            result=self.client.post('/api/v1/remote/targets/worker1/join',headers=self.headers,json=self.body)
        self.assertEqual(result.status_code,409)
        self.assertEqual(self.calls,[])

    def test_ssh_options_and_no_secret_in_process_arguments(self):
        result=self.client.post('/api/v1/remote/targets/worker1/check',headers=self.headers)
        self.assertEqual(result.status_code,200)
        command,kwargs=self.calls[-1]
        self.assertIn('StrictHostKeyChecking=yes',command)
        self.assertIn('BatchMode=yes',command)
        self.assertIn('ojas@10.210.0.2',command)
        self.assertFalse(kwargs['check'])

    def start_without_thread(self):
        with patch('pool_dashboard.remote.threading.Thread'):
            result=self.client.post('/api/v1/remote/targets/worker1/join',headers=self.headers,json=self.body)
        self.assertEqual(result.status_code,202,result.text)
        return result.json()['job_id']

    def test_job_steps_redaction_and_duplicate_guard(self):
        job_id=self.start_without_thread()
        result=self.client.post('/api/v1/remote/targets/worker1/join',headers=self.headers,json=self.body)
        self.assertEqual(result.status_code,409)
        self.remote.execute(job_id,self.settings.ssh_targets['worker1'],JoinRequest(**self.body))
        result=self.client.get('/api/v1/remote/jobs/'+job_id,headers=self.headers)
        self.assertEqual(result.json()['state'],'succeeded')
        self.assertNotIn('secret-token',result.text)
        self.assertIn('[REDACTED]',result.text)
        self.assertEqual(len(self.calls),4)
        self.assertEqual(self.calls[2][1]['input'],'secret-token\n')
        self.assertNotIn('secret-token',str([call[0] for call in self.calls]))
        self.assertFalse(self.remote.active)

    def test_failure_stops_before_join_and_timeout_hides_secret(self):
        job_id=self.start_without_thread()
        self.remote.runner=lambda *args,**kwargs: subprocess.CompletedProcess(args,1,stdout='already installed')
        self.remote.execute(job_id,self.settings.ssh_targets['worker1'],JoinRequest(**self.body))
        self.assertEqual(self.remote.get(job_id)['state'],'failed')
        self.assertEqual(len(self.remote.get(job_id)['logs']),3)
        job_id=self.start_without_thread()
        def timeout(*args,**kwargs):
            raise subprocess.TimeoutExpired('secret-token',30,output='secret-token')
        self.remote.runner=timeout
        self.remote.execute(job_id,self.settings.ssh_targets['worker1'],JoinRequest(**self.body))
        self.assertNotIn('secret-token',str(self.remote.get(job_id)))
        self.assertEqual(self.remote.get(job_id)['state'],'failed')
