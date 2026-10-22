"""Read-only cluster inspection and explicit plans; no shell=True or remote execution."""
import ipaddress
import json
import shlex
import sqlite3
import subprocess
import yaml
from threading import Lock
from fastapi import HTTPException


class ClusterService:
    def __init__(self, settings, runner=subprocess.run):
        self.settings, self.runner = settings, runner
        self.lock = Lock()

    def command(self, args):
        try:
            result = self.runner([*self.settings.command_prefix, *args],
                                 capture_output=True, text=True, timeout=20, check=True)
            return result.stdout
        except (OSError, subprocess.SubprocessError):
            # stderr can contain token-bearing command arguments; never return it.
            raise HTTPException(503, 'Cluster command failed or timed out. Check local k8s access; a token request may need verification before retrying.')

    def nodes(self):
        try:
            data = json.loads(self.command(['kubectl', 'get', 'nodes', '-o', 'json', '--request-timeout=10s']))
            nodes = []
            for node in data.get('items', []):
                labels = node.get('metadata', {}).get('labels', {})
                status = node.get('status', {})
                roles = [label.split('/')[-1] for label in labels if label.startswith('node-role.kubernetes.io/')]
                # Kubernetes workers commonly have no explicit role label.
                if not roles:
                    roles = ['worker']
                nodes.append({'name': node['metadata']['name'],
                              'roles': roles,
                              'ready': any(x.get('type') == 'Ready' and x.get('status') == 'True' for x in status.get('conditions', [])),
                              'addresses': status.get('addresses', []),
                              'cpu': status.get('allocatable', {}).get('cpu'),
                              'memory': status.get('allocatable', {}).get('memory'),
                              'gpu': status.get('allocatable', {}).get('nvidia.com/gpu', '0')})
            return nodes
        except (ValueError, KeyError, TypeError):
            raise HTTPException(502, 'Unexpected cluster node response')

    def join_token(self, node_name):
        if not self.settings.allow_token_generation:
            raise HTTPException(409, 'Development mode: enable allow_token_generation in this app config after reviewing control-plane privileges.')
        # Only this bounded allowlisted operation mutates cluster membership tokens.
        with self.lock:
            if any(node['name'] == node_name for node in self.nodes()):
                raise HTTPException(409, 'Node name is already registered.')
            token = self.command(['get-join-token', node_name, '--worker']).strip()
        if not token:
            raise HTTPException(502, 'The control plane returned no token.')
        return {'node_name': node_name, 'token': token,
                'instructions': 'Use this once on the worker with the join wizard. Treat it as a secret.'}

    def module_plan(self, request, role):
        filename = role + '-config.yaml'
        script = self.settings.scripts_root / 'k8s/cluster' / (
            'setup-worker.sh' if role == 'worker' else 'setup-control-plane.sh')
        config = {'role': role, 'node_name': request.node_name, 'vpn': 'none',
                  'kubernetes': {'channel': self.settings.snap_channel,
                                 'node_address': request.address,
                                 'join_token': getattr(request, 'token', ''), 'addons': []},
                  'image_recovery': {'enabled': False}}
        return {'config_filename': filename, 'config_yaml': yaml.safe_dump(config, sort_keys=False),
                'module_command': shlex.join(['sudo','bash',str(script), filename])}

    def join_plan(self, request):
        if any(node['name'] == request.node_name for node in self.nodes()):
            raise HTTPException(409, 'Node name is already registered.')
        command = shlex.join(['sudo', 'k8s', 'join-cluster', request.token,
                              '--name=' + request.node_name, '--address=' + request.address])
        return {**self.module_plan(request, 'worker'), 'mode': 'plan-only', 'execute_on': 'worker',
                'commands': [shlex.join(['sudo', 'snap', 'install', 'k8s', '--classic', '--channel=' + self.settings.snap_channel]),
                             command, 'sudo k8s status'],
                'note': 'Run on the intended worker after VPN connectivity is verified. Do not run on the dashboard/control-plane machine. Token is not persisted.'}

    def create_plan(self, request):
        return {**self.module_plan(request, 'control'), 'mode': 'plan-only', 'execute_on': 'new-control-plane',
                'commands': [shlex.join(['sudo', 'snap', 'install', 'k8s', '--classic', '--channel=' + self.settings.snap_channel]),
                             shlex.join(['sudo', 'k8s', 'bootstrap', '--name=' + request.node_name, '--address=' + request.address])],
                'note': 'Use a fresh intended control-plane machine. This dashboard does not reset or bootstrap its current cluster.'}


class NetworkStore:
    """VPN DESIGN METADATA ONLY: never claims to apply WireGuard or firewall rules."""
    def __init__(self, settings):
        self.settings = settings
        self.path = settings.state_dir / 'networks.sqlite3'
        with self.connect() as db:
            db.executescript('''CREATE TABLE IF NOT EXISTS networks (name TEXT PRIMARY KEY, subnet TEXT UNIQUE NOT NULL);
                CREATE TABLE IF NOT EXISTS members (network TEXT, email TEXT, PRIMARY KEY(network,email),
                FOREIGN KEY(network) REFERENCES networks(name) ON DELETE CASCADE);''')
            first = next(ipaddress.ip_network(settings.vpn_pool).subnets(new_prefix=24))
            db.execute('INSERT OR IGNORE INTO networks VALUES (?,?)', ('company-wide', str(first)))

    def connect(self):
        db = sqlite3.connect(self.path)
        db.execute('PRAGMA foreign_keys=ON')
        return db

    def list(self):
        with self.connect() as db:
            return [{'name': n, 'subnet': s, 'state': 'planned — not applied',
                     'members': [row[0] for row in db.execute('SELECT email FROM members WHERE network=? ORDER BY email', (n,))]}
                    for n, s in db.execute('SELECT name,subnet FROM networks ORDER BY name')]

    def create(self, name):
        with self.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            if db.execute('SELECT 1 FROM networks WHERE name=?', (name,)).fetchone():
                raise HTTPException(409, 'Network name already exists')
            used = [ipaddress.ip_network(row[0]) for row in db.execute('SELECT subnet FROM networks')]
            used += [ipaddress.ip_network(s) for s in self.settings.reserved_cidrs]
            for subnet in ipaddress.ip_network(self.settings.vpn_pool).subnets(new_prefix=24):
                if not any(subnet.overlaps(x) for x in used):
                    db.execute('INSERT INTO networks VALUES (?,?)', (name, str(subnet)))
                    return {'name': name, 'subnet': str(subnet), 'state': 'planned — not applied'}
        raise HTTPException(409, 'No unused VPN subnets remain')

    def member(self, name, email, remove=False):
        with self.connect() as db:
            if not db.execute('SELECT 1 FROM networks WHERE name=?', (name,)).fetchone():
                raise HTTPException(404, 'Network not found')
            if remove:
                db.execute('DELETE FROM members WHERE network=? AND email=?', (name, email))
            else:
                db.execute('INSERT OR IGNORE INTO members VALUES (?,?)', (name, email))
        return {'status': 'metadata updated', 'applied_to_wireguard': False}
