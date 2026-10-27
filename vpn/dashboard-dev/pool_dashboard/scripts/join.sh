#!/usr/bin/env bash
# Download, inspect, then run as the worker user. Changes require --execute.
# This script is served verbatim; no server-side shell interpolation is used.
set -Eeuo pipefail
exec python3 - "$@" <<'PYWORKER'
import argparse, base64, hashlib, ipaddress, json, os, re, shlex, shutil
import socket, subprocess, sys, time
from pathlib import Path
from urllib.error import HTTPError
from urllib.parse import urlparse
from urllib.request import Request, urlopen

p=argparse.ArgumentParser(description='Invitation + device-code worker onboarding')
p.add_argument('--server',required=True)
p.add_argument('--invite',required=True)
p.add_argument('--execute',action='store_true',help='Authorize local WireGuard installation/configuration and Kubernetes join')
a=p.parse_args()
hostname=socket.gethostname().lower().rstrip('.')
if not re.fullmatch(r'[a-z0-9](?:[a-z0-9.-]{0,61}[a-z0-9])?',hostname):
    sys.exit('Worker hostname must be a valid Kubernetes node name. Configure it locally before joining.')
base=a.server.rstrip('/')
url=urlparse(base)
if url.scheme!='https' and url.hostname not in ('localhost','127.0.0.1'):
    sys.exit('Use the HTTPS dashboard URL.')
if url.username or url.password or url.query or url.fragment:
    sys.exit('Use a plain dashboard base URL, without credentials/query/fragment.')
for tool in ('wg','snap','sudo','ping'):
    if not shutil.which(tool):
        sys.exit('Missing '+tool+'. Install prerequisites locally first: sudo apt-get install -y wireguard-tools wireguard snapd python3 iputils-ping')

state=Path.home()/'.local/state/pool-worker'
state.mkdir(parents=True,exist_ok=True,mode=0o700); state.chmod(0o700)
def save(path,data):
    fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_TRUNC,0o600)
    os.fchmod(fd,0o600)
    with os.fdopen(fd,'w') as f:f.write(data)

machine_file=Path('/etc/machine-id')
if not machine_file.is_file() or not machine_file.read_text().strip():
    sys.exit('A stable /etc/machine-id is required before worker enrollment.')
machine_id=hashlib.sha256(('pool-machine-v1\n'+machine_file.read_text().strip()).encode()).hexdigest()
if subprocess.run(['snap','list','k8s'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode==0:
    sys.exit('This machine already has Kubernetes installed. Existing worker/control-plane machines cannot join another cluster.')
key=state/'private-key'
if not key.exists():
    private=subprocess.check_output(['wg','genkey'],text=True)
    fd=os.open(key,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
    with os.fdopen(fd,'w') as f:f.write(private)
key.chmod(0o600)
private=key.read_text().strip()
public=subprocess.check_output(['wg','pubkey'],input=private+'\n',text=True).strip()

def api(path,data=None,token=None):
    headers={'Content-Type':'application/json','ngrok-skip-browser-warning':'true'}
    if token:headers['Authorization']='Bearer '+token
    request=Request(base+'/api/v1/enroll'+path,
                    data=json.dumps(data).encode() if data is not None else None,headers=headers)
    try:
        with urlopen(request,timeout=25) as response:return json.load(response)
    except HTTPError as e:
        try:detail=json.load(e).get('detail','Request failed')
        except Exception:detail='Request failed'
        raise RuntimeError(str(e.code)+': '+str(detail))

request_file=state/'device-request.json'
fingerprint=hashlib.sha256((base+'\n'+a.invite+'\n'+hostname+'\n'+public).encode()).hexdigest()
device=None
if request_file.exists():
    previous=json.loads(request_file.read_text())
    if previous.get('fingerprint')==fingerprint and previous.get('expires',0)>time.time():device=previous
if device is None:
    device=api('/device',{'invitation':a.invite,'public_key':public,'hostname':hostname,'machine_id':machine_id})
    device.update(fingerprint=fingerprint,expires=time.time()+device['expires_in'])
    save(request_file,json.dumps(device))
print('Authenticate this worker in your browser: '+device['verification_uri_complete'],flush=True)
print('Device code: '+device['user_code'],flush=True)
print('Sign in (or register with the invitation), review the device, and authorize it. An administrator must then approve the peer.',flush=True)
grant=None
while time.time()<device['expires']:
    result=api('/token',{'device_code':device['device_code']})
    if result.get('access_token'):
        grant=result['access_token'];break
    print('Waiting: '+result['state'],flush=True)
    time.sleep(max(5,result.get('interval',5)))
if not grant:sys.exit('Device authorization expired. Ask the administrator for a new invitation.')
vpn=api('/vpn-config',token=grant)
if vpn['node_name']!=hostname:sys.exit('Invitation is for a different worker hostname; no host changes performed.')
ipaddress.IPv4Interface(vpn['address']); ipaddress.IPv4Address(vpn['server_address'])
if len(base64.b64decode(vpn['public_key'],validate=True))!=32:sys.exit('Invalid hub public key')
if not re.fullmatch(r'[A-Za-z0-9.\-]+:[0-9]{1,5}',vpn['endpoint']):sys.exit('Invalid hub endpoint')
routes=[ipaddress.IPv4Network(s.strip()) for s in vpn['allowed_ips'].split(',')]
if any(r.prefixlen==0 for r in routes):sys.exit('Default-route VPN configurations are not accepted by this worker helper.')
conf=('[Interface]\nPrivateKey = '+private+'\nAddress = '+vpn['address']+
      '\n\n[Peer]\nPublicKey = '+vpn['public_key']+'\nEndpoint = '+vpn['endpoint']+
      '\nAllowedIPs = '+', '.join(map(str,routes))+'\nPersistentKeepalive = 25\n')
config_file=state/'pool0.conf';save(config_file,conf)
commands=[['sudo','install','-d','-m','700','/etc/wireguard'],
          ['sudo','install','-m','600',str(config_file),'/etc/wireguard/pool0.conf'],
          ['sudo','systemctl','enable','--now','wg-quick@pool0']]
print('Worker VPN commands (private key stays local):',flush=True)
for command in commands:print(shlex.join(command),flush=True)
if a.execute:
    subprocess.run(['sudo','-v'],check=True)
    if subprocess.run(['snap','list','k8s'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL).returncode==0:
        sys.exit('k8s already installed: review the existing node manually; no join or VPN overwrite was performed.')
    if subprocess.run(['sudo','test','-e','/etc/wireguard/pool0.conf']).returncode==0:
        sys.exit('Existing pool0.conf found. Review it manually instead of overwriting it.')
    record={'version':1,'role':'worker','node_name':vpn['node_name'],'server':base,'public_key':public,'vpn_installed':False,'k8s_installed':False}
    save(state/'installation.json',json.dumps(record))
    for command in commands:
        subprocess.run(command,check=True)
        if command[1]=='install' and command[-1]=='/etc/wireguard/pool0.conf':
            record['vpn_installed']=True
            save(state/'installation.json',json.dumps(record))
else:
    print('Preview mode: execute the reviewed VPN commands in another terminal. This script will wait for the hub handshake; Ctrl+C to stop.',flush=True)

cluster=None
deadline=min(device['expires'],time.time()+600)
while time.time()<deadline:
    subprocess.run(['ping','-c','1','-W','2',vpn['server_address']],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    try:
        cluster=api('/cluster-config',{},grant);break
    except RuntimeError as e:
        if not str(e).startswith('409: Connect WireGuard'):raise
        time.sleep(5)
if not cluster:sys.exit('No verified WireGuard handshake. Check the UDP endpoint, routing and firewall; no Kubernetes token was issued.')
node=cluster['node_name'];address=cluster['address']
if not re.fullmatch(r'[a-z0-9][a-z0-9.-]{0,62}',node):sys.exit('Invalid node name')
ipaddress.IPv4Address(address)
save(state/'cluster-config.json',json.dumps(cluster))
commands=[['sudo','snap','install','k8s','--classic','--channel='+cluster['channel']],
          ['sudo','k8s','join-cluster',cluster['token'],'--name='+node,'--address='+address],
          ['sudo','k8s','status','--wait-ready','--timeout','5m']]
print('VPN verified. Kubernetes commands below contain a sensitive join token:',flush=True)
for command in commands:print(shlex.join(command),flush=True)
if a.execute:
    for command in commands:
        subprocess.run(command,check=True)
        if command[1:4]==['snap','install','k8s']:
            record['k8s_installed']=True
            save(state/'installation.json',json.dumps(record))
    (state/'cluster-config.json').unlink()
    request_file.unlink(missing_ok=True)
    print('Worker joined. Refresh the administrator dashboard to check Kubernetes readiness.',flush=True)
else:
    print('Commands were not executed. A protected local copy is in '+str(state/'cluster-config.json')+'. Remove it after use.',flush=True)
PYWORKER
