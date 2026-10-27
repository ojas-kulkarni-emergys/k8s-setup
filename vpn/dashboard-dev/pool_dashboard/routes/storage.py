"""Generate host-specific storage commands; never access browser-entered paths."""
import ipaddress
import re
import shlex
from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel, Field, field_validator

router=APIRouter(prefix='/api/v1/storage',tags=['shared-storage'])


class StoragePlan(BaseModel):
    mode: str=Field(pattern=r'^(export|mount|rsync)$')
    name: str=Field(default='model-cache',pattern=r'^[a-z0-9][a-z0-9-]{0,31}$')
    path: str=Field(default='/srv/model-cache/huggingface',max_length=512)
    source: str=Field(default='/home/ojas/.cache/huggingface/hub',max_length=512)
    mountpoint: str=Field(default='/mnt/model-cache',max_length=512)
    server: str
    clients: list[str]=Field(default_factory=list,max_length=100)
    access: str=Field(default='selected',pattern=r'^(selected|all-vpn)$')
    user: str=Field(default='ojas',pattern=r'^[a-z_][a-z0-9_-]{0,31}$')

    @field_validator('path','source','mountpoint')
    @classmethod
    def safe_path(cls,value):
        # NFS export syntax needs its own escaping; restrict to simple absolute
        # paths rather than emitting a misleading shell-quoted /etc/exports line.
        if not re.fullmatch(r'/[A-Za-z0-9_./-]+',value) or '..' in value.split('/') or value=='/':
            raise ValueError('Use a simple absolute directory path without whitespace or traversal.')
        return value.rstrip('/')

    @field_validator('server')
    @classmethod
    def safe_server(cls,value):
        address=ipaddress.IPv4Address(value)
        if address.is_unspecified or address.is_multicast or address.is_loopback:
            raise ValueError('Use the reachable storage/target device IPv4 address.')
        return str(address)

    @field_validator('clients')
    @classmethod
    def safe_clients(cls,values):
        return [cls.safe_server(v) for v in values]


@router.get('/clients')
def clients(request: Request):
    settings=request.app.state.settings
    pool=ipaddress.IPv4Network(settings.vpn_pool)
    tailscale=ipaddress.IPv4Network('100.64.0.0/10')
    found={}
    def add(name,address,source):
        try: ip=ipaddress.IPv4Address(address)
        except (ValueError,TypeError): return
        if ip in pool or ip in tailscale:
            found.setdefault(str(ip),{'name':name,'address':str(ip),'source':source})
    for peer in request.app.state.enrollment.list():
        if peer['state'] in ('approved','connected') and peer.get('address'):
            add(peer['node_name'],peer['address'],'WireGuard peer')
    add('VPN host',settings.wireguard.get('server_address',''),'WireGuard host')
    note=''
    try:
        for node in request.app.state.cluster.nodes():
            for address in node['addresses']:
                if address['type']=='InternalIP':add(node['name'],address['address'],'Kubernetes node')
    except HTTPException:
        note='Cluster inventory unavailable; showing recorded WireGuard addresses.'
    return {'clients':sorted(found.values(),key=lambda x:(x['name'],x['address'])),
            'vpn_pool':str(pool),'inventory_note':note}


@router.post('/plan')
def plan(body: StoragePlan,request: Request):
    q=shlex.quote
    if body.mode=='export':
        allowed=list(dict.fromkeys(body.clients))
        if body.access=='all-vpn':
            pool=ipaddress.IPv4Network(request.app.state.settings.vpn_pool)
            if pool.prefixlen==0: raise HTTPException(409,'VPN pool must not be a default route.')
            allowed=[str(pool)]
        if not allowed: raise HTTPException(422,'Select at least one VPN client or allow the configured VPN pool.')
        line=body.path+' '+ ' '.join(ip+'(ro,sync,no_subtree_check,root_squash)' for ip in allowed)
        commands=['sudo apt-get update','sudo apt-get install -y nfs-kernel-server rsync',
                  shlex.join(['sudo','mkdir','-p',body.path]),'sudo install -d -m 0755 /etc/exports.d',
                  'sudo tee '+q('/etc/exports.d/pool-'+body.name+'.exports')+" >/dev/null <<'POOL_EXPORT'\n"+line+'\nPOOL_EXPORT',
                  'sudo exportfs -rav','sudo systemctl enable --now nfs-kernel-server','sudo exportfs -v']
        where='storage server '+body.server
        note='The dedicated export file is replaced when run. Preserve any previous clients. Ensure exported files are readable with root_squash; permissions are not changed automatically. Allow TCP 2049 only from approved VPN clients.'
    elif body.mode=='mount':
        commands=['sudo apt-get update','sudo apt-get install -y nfs-common',
                  shlex.join(['sudo','mkdir','-p',body.mountpoint]),
                  shlex.join(['sudo','mount','-t','nfs','-o','ro,vers=4.1',body.server+':'+body.path,body.mountpoint]),
                  shlex.join(['findmnt',body.mountpoint]),shlex.join(['ls',body.mountpoint]),
                  '# When finished: '+shlex.join(['sudo','umount',body.mountpoint])]
        where='client / worker device'
        note='Manual mount is a test. Kubernetes can mount the export directly; every eligible node still needs nfs-common and network/export permission. No fstab entry is added.'
    else:
        destination=body.user+'@'+body.server+':'+body.path+'/'
        preview=shlex.join(['rsync','-a','--protect-args','--dry-run','--',body.source+'/',destination])
        actual=shlex.join(['rsync','-a','--protect-args','--',body.source+'/',destination])
        commands=['sudo apt-get install -y rsync openssh-client',preview,
                  '# After reviewing the dry run:',actual]
        where='device containing the source directory'
        note='Copies source contents over SSH into the remote destination; destination permissions/SSH access must already exist and remote rsync must be installed. No --delete is used. rsync copies files; NFS instead serves them over the network.'
    return {'mode':'commands-only','execute_on':where,'commands':commands,'note':note,
            'reference':'k8s/nfs-shared.sh (unchanged)',
            'kubernetes_volume':{'name':'hf-cache','nfs':{'server':body.server,'path':body.path,'readOnly':True}} if body.mode in ('export','mount') else None}
