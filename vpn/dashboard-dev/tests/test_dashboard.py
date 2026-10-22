import json
from pathlib import Path
import subprocess
import tempfile
import unittest
import asyncio
from unittest.mock import patch
import httpx
from pool_dashboard.app import create_app
from pool_dashboard.settings import Settings


class InProcessClient:
    """ASGI integration tests; run mocked sync work inline to avoid portal threads."""
    def __init__(self, app):
        self.app = app

    def request(self, method, path, **kwargs):
        async def inline(function, *args, **_options):
            return function(*args)
        async def send():
            with patch('anyio.to_thread.run_sync', inline):
                async with httpx.AsyncClient(transport=httpx.ASGITransport(self.app), base_url='http://test') as client:
                    return await client.request(method,path,**kwargs)
        return asyncio.run(send())

    def get(self,path,**kwargs):
        return self.request('GET',path,**kwargs)

    def post(self,path,**kwargs):
        return self.request('POST',path,**kwargs)


class DashboardTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.calls = []
        self.settings = Settings(state_dir=Path(self.tmp.name), scripts_root=Path('/tmp'),
                                 command_prefix=['k8s'], reserved_cidrs=('10.1.0.0/16',))
        def runner(command, **kwargs):
            self.calls.append(command)
            if 'get-join-token' in command:
                return subprocess.CompletedProcess(command, 0, stdout='join-secret\n')
            return subprocess.CompletedProcess(command, 0, stdout=json.dumps({'items':[
                {'metadata':{'name':'control1','labels':{'node-role.kubernetes.io/control-plane':''}},
                 'status':{'conditions':[{'type':'Ready','status':'True'}],
                           'addresses':[{'type':'InternalIP','address':'100.78.103.3'}],
                           'allocatable':{'cpu':'8','memory':'8Gi'}}}]}))
        self.client = InProcessClient(create_app(self.settings, runner=runner, token='test-admin-token'))
        self.headers = {'Authorization':'Bearer test-admin-token'}

    def test_api_requires_admin_and_disables_caching(self):
        response=self.client.get('/api/v1/cluster/nodes')
        self.assertEqual(response.status_code,401)
        self.assertEqual(self.calls,[])
        self.assertEqual(response.headers['cache-control'],'no-store')
        response=self.client.get('/api/v1/cluster/nodes',headers=self.headers)
        self.assertEqual(response.json()['nodes'][0]['name'],'control1')

    def test_join_and_create_generate_plans_never_run_join_or_bootstrap(self):
        data={'node_name':'worker2','address':'100.81.95.34','token':'secret'}
        response=self.client.post('/api/v1/setup/join',headers=self.headers,json=data)
        self.assertEqual(response.status_code,200,response.text)
        self.assertEqual(response.json()['execute_on'],'worker')
        self.assertIn('setup-worker.sh',response.json()['module_command'])
        self.assertIn('join_token: secret',response.json()['config_yaml'])
        self.assertIn('join-cluster secret',response.json()['commands'][1])
        response=self.client.post('/api/v1/setup/create',headers=self.headers,json={k:v for k,v in data.items() if k!='token'})
        self.assertEqual(response.status_code,200,response.text)
        self.assertEqual(response.json()['execute_on'],'new-control-plane')
        self.assertFalse(any('join-cluster' in cmd or 'bootstrap' in cmd for cmd in self.calls))

    def test_token_generation_is_opt_in(self):
        response=self.client.post('/api/v1/cluster/join-token',headers=self.headers,json={'node_name':'worker2'})
        self.assertEqual(response.status_code,409)
        self.assertEqual(self.calls,[])
        self.settings.allow_token_generation=True
        response=self.client.post('/api/v1/cluster/join-token',headers=self.headers,json={'node_name':'worker2'})
        self.assertEqual(response.json()['token'],'join-secret')
        self.assertEqual(self.calls[-1],['k8s','get-join-token','worker2','--worker'])

    def test_existing_node_and_injection_rejected(self):
        self.settings.allow_token_generation=True
        response=self.client.post('/api/v1/cluster/join-token',headers=self.headers,json={'node_name':'control1'})
        self.assertEqual(response.status_code,409)
        response=self.client.post('/api/v1/cluster/join-token',headers=self.headers,json={'node_name':'x;touch /tmp/bad'})
        self.assertEqual(response.status_code,422)
        self.assertFalse(any('get-join-token' in cmd for cmd in self.calls))

    def test_networks_and_members_are_planning_metadata(self):
        response=self.client.post('/api/v1/vpn/networks',headers=self.headers,json={'name':'project-a'})
        self.assertEqual(response.status_code,201)
        self.assertEqual(response.json()['subnet'],'10.210.1.0/24')
        response=self.client.post('/api/v1/vpn/networks/project-a/members',headers=self.headers,json={'email':'a@example.com'})
        self.assertFalse(response.json()['applied_to_wireguard'])
        networks=self.client.get('/api/v1/vpn/networks',headers=self.headers).json()['networks']
        self.assertEqual(next(n for n in networks if n['name']=='project-a')['members'],['a@example.com'])
        self.client.request('DELETE','/api/v1/vpn/networks/project-a/members',headers=self.headers,json={'email':'a@example.com'})
        self.assertEqual(self.calls,[])

    def test_static_ui_and_empty_state(self):
        response=self.client.get('/')
        self.assertEqual(response.status_code,200)
        self.assertIn('Node setup wizard',response.text)
        self.assertIn('not enabled',response.text)
        self.assertIn("frame-ancestors 'none'",response.headers['content-security-policy'])
        for path in ('/static/app.js','/static/style.css'):
            self.assertEqual(self.client.get(path).status_code,200)

    def test_secret_not_written_to_network_database(self):
        self.settings.allow_token_generation=True
        self.client.post('/api/v1/cluster/join-token',headers=self.headers,json={'node_name':'worker2'})
        self.assertNotIn(b'join-secret',(self.settings.state_dir/'networks.sqlite3').read_bytes())

    def test_failed_command_does_not_expose_arguments(self):
        def fail(command,**kwargs):
            raise subprocess.CalledProcessError(1,command,stderr='private internal token')
        self.client.app.state.cluster.runner=fail
        response=self.client.get('/api/v1/cluster/nodes',headers=self.headers)
        self.assertEqual(response.status_code,503)
        self.assertNotIn('private internal token',response.text)
