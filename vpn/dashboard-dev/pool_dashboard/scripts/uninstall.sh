#!/usr/bin/env bash
# Run as the same worker user that ran join.sh. Default: commands only.
set -Eeuo pipefail
exec python3 - "$@" <<'PYWORKER'
import argparse, json, re, shlex, subprocess, sys
from pathlib import Path

p=argparse.ArgumentParser(description='Disconnect or uninstall a dashboard-managed worker')
p.add_argument('--scope',choices=('disconnect','vpn','cluster','all'),default='disconnect')
p.add_argument('--execute',action='store_true')
p.add_argument('--confirm-node',default='')
p.add_argument('--node-removed',action='store_true',help='Confirm administrator already removed this worker from the cluster')
a=p.parse_args()
state=Path.home()/'.local/state/pool-worker'
record_path=state/'installation.json'
if not record_path.is_file():sys.exit('No wizard installation record. Review this machine manually; nothing was changed.')
record=json.loads(record_path.read_text())
node=record.get('node_name','')
if record.get('role')!='worker' or not re.fullmatch(r'[a-z0-9][a-z0-9.-]{0,62}',node):
    sys.exit('Invalid worker installation record; nothing was changed.')
cluster=a.scope in ('cluster','all')
vpn=a.scope in ('disconnect','vpn','all')
commands=[]
if cluster:
    if not record.get('k8s_installed'):sys.exit('This wizard did not install k8s. Refusing to remove it.')
    print('First, on the CONTROL PLANE (keep the worker VPN connected):')
    print('sudo k8s remove-node '+node)
    print('sudo k8s kubectl get nodes')
    commands.append(['sudo','snap','remove','k8s'])
if vpn:
    if not record.get('vpn_installed'):sys.exit('This wizard did not install pool0. Refusing to change it.')
    commands.append(['sudo','systemctl','disable','--now','wg-quick@pool0'])
    if a.scope!='disconnect':commands.append(['sudo','rm','--','/etc/wireguard/pool0.conf'])
print('WORKER commands:')
for command in commands:print(shlex.join(command))
print('Administrator: revoke this worker invitation in the dashboard to remove its server-side WireGuard peer.')
if not a.execute:sys.exit('Preview only. Add --execute --confirm-node '+node+' after review.')
if a.confirm_node!=node:sys.exit('--confirm-node must match '+node)
if cluster and not a.node_removed:sys.exit('Remove the worker on the control plane first, then add --node-removed.')
subprocess.run(['sudo','-v'],check=True)
if cluster:
    # Refuse a machine with control-plane service configuration, even if its local record says worker.
    for service in ('kube-apiserver','etcd','k8s-dqlite'):
        if subprocess.run(['sudo','test','-e','/var/snap/k8s/common/args/'+service]).returncode==0:
            sys.exit('Control-plane configuration detected. Automatic uninstall refused.')
if vpn:
    # Compare the installed interface private key locally; never print or transmit it.
    result=subprocess.run(['sudo','cat','/etc/wireguard/pool0.conf'],capture_output=True,text=True,check=True)
    match=re.search(r'^PrivateKey\s*=\s*(\S+)\s*$',result.stdout,re.M)
    if not match:sys.exit('Cannot verify pool0 ownership. Nothing was changed.')
    public=subprocess.check_output(['wg','pubkey'],input=match[1]+'\n',text=True).strip()
    if public!=record.get('public_key'):sys.exit('pool0 belongs to another installation. Nothing was changed.')
for command in commands:
    subprocess.run(command,check=True)
    if command[1:4]==['snap','remove','k8s']:record['k8s_installed']=False
    if command[1]=='rm':record['vpn_installed']=False
    record_path.write_text(json.dumps(record));record_path.chmod(0o600)
if not record.get('vpn_installed') and not record.get('k8s_installed'):
    for filename in ('private-key','pool0.conf','device-request.json','cluster-config.json','installation.json'):
        (state/filename).unlink(missing_ok=True)
print('Completed. Shared packages, model caches, NFS shares and other VPN interfaces were preserved.')
PYWORKER
