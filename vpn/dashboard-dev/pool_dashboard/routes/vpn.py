from fastapi import APIRouter, Request
from ..models import NetworkRequest, MemberRequest
import ipaddress
import re
import shlex
from fastapi import HTTPException
from pydantic import BaseModel
router = APIRouter(prefix='/api/v1/vpn', tags=['vpn-development'])


class PeerApproval(BaseModel):
    apply: bool=False


@router.get('/peers')
def peers(request: Request):
    return {'peers':request.app.state.enrollment.list(),
            'apply_enabled':request.app.state.settings.wireguard.get('apply_peers',False)}


@router.post('/peers/{code}/approve')
def approve_peer(code: str,body: PeerApproval,request: Request):
    return request.app.state.enrollment.approve(code,body.apply)


@router.get('/hub-plan')
def hub_plan(request: Request):
    settings=request.app.state.settings
    interface=settings.wireguard.get('interface','pool0')
    if not re.fullmatch(r'pool[0-9]{1,2}',interface):
        raise HTTPException(409,'Use a dedicated pool0..pool99 hub interface.')
    address=ipaddress.IPv4Address(settings.wireguard.get('server_address','10.210.0.1'))
    pool=ipaddress.IPv4Network(settings.vpn_pool)
    if address not in pool: raise HTTPException(409,'Hub address must belong to vpn_pool.')
    config='/etc/wireguard/'+interface+'.conf'
    # These are reviewed commands, never executed by this endpoint.
    script=('umask 077; test ! -e '+shlex.quote(config)+' || exit 1; '
            '{ printf '+shlex.quote('[Interface]\nAddress = '+str(address)+'/'+str(pool.prefixlen)+
                                    '\nListenPort = 51820\nSaveConfig = true\nPrivateKey = ')+
            '; wg genkey; } > '+shlex.quote(config))
    return {'mode':'commands-only','commands':[
        'sudo apt-get update','sudo apt-get install -y wireguard wireguard-tools',
        'sudo install -d -m 700 /etc/wireguard',shlex.join(['sudo','sh','-c',script]),
        "printf '%s\\n' 'net.ipv4.ip_forward=1' | sudo tee /etc/sysctl.d/90-pool-forward.conf >/dev/null",
        'sudo sysctl -p /etc/sysctl.d/90-pool-forward.conf',
        shlex.join(['sudo','systemctl','enable','--now','wg-quick@'+interface]),
        shlex.join(['sudo','wg','show',interface,'public-key'])],
        'endpoint':settings.wireguard.get('endpoint',''),
        'note':'Run on the control plane, after checking routing/address conflicts. Existing config is never overwritten. Allow UDP 51820 on the actual host/network firewall and required Kubernetes/Cilium traffic between approved nodes; IP forwarding alone does not override firewall drops. Include the existing advertised control-plane IP in worker AllowedIPs. The ngrok HTTP tunnel cannot carry WireGuard UDP. These commands do not replace Tailscale or enforce logical-network isolation.'}


@router.get('/networks')
def networks(request: Request):
    return {'networks': request.app.state.networks.list(),
            'enforcement': 'logical-network isolation not implemented; peer enrollment is separately opt-in'}


@router.post('/networks', status_code=201)
def create_network(body: NetworkRequest, request: Request):
    return request.app.state.networks.create(body.name)


@router.post('/networks/{name}/members')
def add_member(name: str, body: MemberRequest, request: Request):
    return request.app.state.networks.member(name, body.email)


@router.delete('/networks/{name}/members')
def remove_member(name: str, body: MemberRequest, request: Request):
    return request.app.state.networks.member(name, body.email, remove=True)
