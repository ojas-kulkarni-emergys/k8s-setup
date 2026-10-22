"""Allowlisted worker operations over SSH; no arbitrary browser-supplied commands."""
import ipaddress
import re
import shlex
import subprocess
import threading
import uuid
from fastapi import HTTPException


class RemoteWorkers:
    def __init__(self, settings, cluster, runner=subprocess.run):
        self.settings, self.cluster, self.runner = settings, cluster, runner
        self.jobs = {}
        self.lock = threading.Lock()
        self.active = set()

    def target(self, name):
        if not self.settings.remote_execution_enabled:
            raise HTTPException(409, 'Remote execution is disabled in dashboard config.yaml.')
        target = self.settings.ssh_targets.get(name)
        if not target:
            raise HTTPException(404, 'Worker is not in the configured SSH target allowlist.')
        try:
            address = ipaddress.ip_address(target['host'])
            port = int(target.get('port', 22))
            if (address.is_loopback or address.is_unspecified or address.is_multicast
                    or not 1 <= port <= 65535
                    or not re.fullmatch(r'[a-z_][a-z0-9_-]*', target['user'])
                    or not str(target['identity_file']).startswith('/')
                    or not str(target['known_hosts_file']).startswith('/')):
                raise ValueError('Invalid SSH target')
        except (KeyError, ValueError, TypeError):
            raise HTTPException(409, 'Invalid SSH target configuration.')
        return target

    def command(self, target, script, secret='', timeout=30):
        # OpenSSH joins remote arguments into a shell command, so quote explicitly.
        args = ['ssh', '-T', '-o', 'BatchMode=yes', '-o', 'StrictHostKeyChecking=yes',
                '-o', 'IdentitiesOnly=yes', '-o', 'ConnectTimeout=10',
                '-o', 'ServerAliveInterval=10', '-o', 'ServerAliveCountMax=3',
                '-o', 'UserKnownHostsFile=' + target['known_hosts_file'],
                '-i', target['identity_file'], '-p', str(target.get('port', 22)),
                target['user'] + '@' + target['host'],
                shlex.join(['bash', '-c', script])]
        return self.runner(args, input=secret, text=True, stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT, timeout=timeout, check=False)

    def check(self, name):
        target = self.target(name)
        try:
            result = self.command(target, 'set -eu; hostname; command -v snap; sudo -n snap list >/dev/null; echo SSH_READY')
        except (OSError, subprocess.SubprocessError):
            raise HTTPException(503, 'SSH check failed or timed out. Verify VPN, host key, SSH key and sudo access.')
        if result.returncode:
            raise HTTPException(503, 'SSH prerequisites failed. Verify SSH authentication, snapd and noninteractive sudo.')
        return {'target': name, 'host': target['host'], 'ready': True}

    def start(self, name, request):
        target = self.target(name)
        if request.address != str(ipaddress.ip_address(target['host'])):
            raise HTTPException(422, 'Worker address must match its configured SSH/VPN address.')
        # A cluster read must succeed; refuse all already-registered nodes, including
        # the control plane, before sending any remote mutation.
        for node in self.cluster.nodes():
            if node['name'] == request.node_name or any(a.get('address') == request.address for a in node['addresses']):
                raise HTTPException(409, 'Target name/address is already registered in this cluster.')
        with self.lock:
            if name in self.active:
                raise HTTPException(409, 'This worker already has an active join job.')
            if len(self.jobs) >= 50:
                oldest = next((key for key, value in self.jobs.items() if value['state'] != 'running'), None)
                if oldest is None:
                    raise HTTPException(409, 'Too many active jobs.')
                del self.jobs[oldest]
            job_id = uuid.uuid4().hex
            self.jobs[job_id] = {'id': job_id, 'target': name, 'state': 'running', 'logs': []}
            self.active.add(name)
        threading.Thread(target=self.execute, args=(job_id, target, request), daemon=True).start()
        return {'job_id': job_id}

    def get(self, job_id):
        with self.lock:
            if job_id not in self.jobs:
                raise HTTPException(404, 'Job not found; jobs expire when the dashboard restarts.')
            return {**self.jobs[job_id], 'logs': list(self.jobs[job_id]['logs'])}

    def log(self, job_id, message, token):
        # Do not return token-bearing CLI output, terminal control sequences or ANSI.
        message = message.replace(token, '[REDACTED]')
        message = re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]', '', message)
        message = ''.join(c for c in message if c in '\n\t' or ord(c) >= 32)
        with self.lock:
            self.jobs[job_id]['logs'].append(message[-12000:])

    def execute(self, job_id, target, request):
        state = 'failed'
        channel = shlex.quote(self.settings.snap_channel)
        node = shlex.quote(request.node_name)
        address = shlex.quote(request.address)
        stages = [
            ('Check worker prerequisites',
             'set -eu; command -v snap; sudo -n snap list >/dev/null; '
             'if sudo -n snap list k8s >/dev/null 2>&1; then '
             'echo "k8s is already installed; review this host manually before joining"; exit 1; fi', '', 30),
            ('Install Canonical Kubernetes', f'set -eu; sudo -n snap install k8s --classic --channel={channel}', '', 1200),
            ('Join worker', f'set -eu; IFS= read -r token; sudo -n k8s join-cluster "$token" --name={node} --address={address}', request.token + '\n', 300),
            ('Check worker readiness', 'sudo -n k8s status --wait-ready --timeout 5m', '', 330),
        ]
        try:
            for title, script, secret, timeout in stages:
                self.log(job_id, title, request.token)
                result = self.command(target, script, secret, timeout)
                if result.stdout:
                    self.log(job_id, result.stdout, request.token)
                if result.returncode:
                    raise RuntimeError('Remote step failed. Review the worker before retrying; no rollback was attempted.')
            state = 'succeeded'
        except (OSError, subprocess.SubprocessError, RuntimeError):
            self.log(job_id, 'Job failed or timed out. Remote changes may have completed; inspect the worker before retrying.', request.token)
            state = 'failed'
        finally:
            with self.lock:
                self.jobs[job_id]['state'] = state
                self.active.discard(self.jobs[job_id]['target'])
