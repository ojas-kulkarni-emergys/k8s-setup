"""Public, scoped worker endpoints and separate administrator operations."""
import time
import shlex
from collections import defaultdict, deque
from threading import Lock
from urllib.parse import urlparse
from fastapi import APIRouter, Depends, HTTPException, Request, Response
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field
from ..models import NodeRequest
from ..security import require_admin

admin=APIRouter(prefix='/api/v1/enrollment',tags=['worker-invitations'],dependencies=[Depends(require_admin)])
public=APIRouter(prefix='/api/v1/enroll',tags=['worker-device-authorization'])
limits=defaultdict(deque)
limit_lock=Lock()


def rate_limit(request: Request):
    key=(request.client.host if request.client else 'local',request.url.path)
    now=time.monotonic()
    with limit_lock:
        if len(limits)>2000:
            for old in list(limits):
                if not limits[old] or limits[old][-1]<now-60: del limits[old]
            if len(limits)>2000: raise HTTPException(429,'Too many requests.')
        queue=limits[key]
        while queue and queue[0]<now-60: queue.popleft()
        if len(queue)>= (10 if request.url.path.endswith(('/login','/register')) else 120):
            raise HTTPException(429,'Slow down and retry later.')
        queue.append(now)


public.dependencies.append(Depends(rate_limit))


class Invite(NodeRequest):
    email: str=Field(pattern=r'^[^\s@]+@[^\s@]+\.[^\s@]+$',max_length=254)
    network: str=Field(pattern=r'^[a-z0-9][a-z0-9-]{0,31}$')
    minutes: int=Field(default=60,ge=5,le=1440)


class Apply(BaseModel):
    apply: bool=False


class Account(BaseModel):
    email: str=Field(min_length=3,max_length=254)
    password: str=Field(min_length=12,max_length=256)
    invitation: str=Field(default='',max_length=128)


class Device(BaseModel):
    invitation: str=Field(min_length=32,max_length=128)
    public_key: str=Field(min_length=44,max_length=44)
    machine_id: str=Field(pattern=r'^[a-f0-9]{64}$')
    hostname: str | None=Field(default=None,pattern=r'^[a-z0-9](?:[a-z0-9.-]{0,61}[a-z0-9])?$')


class Poll(BaseModel):
    device_code: str=Field(min_length=32,max_length=128)


class Code(BaseModel):
    user_code: str=Field(pattern=r'^[A-F0-9]{8}$')


def browser_origin(request):
    # JSON + same-origin checks protect browser cookie operations from CSRF.
    expected=urlparse(request.app.state.settings.public_url)
    if request.headers.get('origin')!=expected.scheme+'://'+expected.netloc:
        raise HTTPException(403,'Use the configured dashboard origin.')


def worker_token(request):
    value=request.headers.get('authorization','')
    if not value.startswith('Bearer '): raise HTTPException(401,'Worker authorization required.')
    return value[7:]


@admin.post('/invitations',status_code=201)
def invite(body: Invite,request: Request):
    return request.app.state.enrollment.create_invite(body.email,body.node_name,body.network,body.minutes)


@admin.get('/invitations')
def invitations(request: Request):
    return {'invitations':request.app.state.enrollment.invitations()}


@admin.get('/devices')
def devices(request: Request):
    return {'devices':request.app.state.enrollment.list()}


@admin.post('/uninstall-plan')
def uninstall_plan(body: NodeRequest,request: Request):
    matches=[d for d in request.app.state.enrollment.list() if d['node_name']==body.node_name]
    if not matches:
        raise HTTPException(404,'No dashboard enrollment exists for this worker.')
    node=next((n for n in request.app.state.cluster.nodes() if n['name']==body.node_name),None)
    if node and any(r in ('control-plane','master') for r in node['roles']):
        raise HTTPException(409,'Control-plane removal is not supported by worker cleanup.')
    base=request.app.state.settings.public_url.rstrip('/')
    return {'mode':'commands-only','node_name':body.node_name,
            'control_plane':['sudo k8s remove-node '+body.node_name,'sudo k8s kubectl get nodes'],
            'worker':['curl --fail --show-error --silent '+shlex.quote(base+'/uninstall.sh')+' -o uninstall.sh',
                      'bash uninstall.sh --scope all',
                      'bash uninstall.sh --scope all --execute --node-removed --confirm-node '+body.node_name],
            'last_step':'After cluster removal and local cleanup, revoke the invitation / VPN peer in this dashboard.',
            'note':'Keep WireGuard connected until remove-node succeeds. Local execution requires the original wizard installation record. Review workloads and local storage before removing the worker.'}


@admin.post('/devices/{code}/approve')
def approve(code: str,body: Apply,request: Request):
    return request.app.state.enrollment.approve(code,body.apply)


@admin.delete('/invitations/{invite_id}')
def revoke(invite_id: str,request: Request):
    return request.app.state.enrollment.revoke(invite_id)


@public.post('/register',status_code=201)
def register(body: Account,request: Request):
    browser_origin(request)
    return request.app.state.enrollment.register(body.invitation,body.email,body.password)


@public.post('/login')
def login(body: Account,request: Request,response: Response):
    browser_origin(request)
    token=request.app.state.enrollment.login(body.email,body.password)
    response.set_cookie('pool-worker-session',token,httponly=True,samesite='strict',
                        secure=urlparse(request.app.state.settings.public_url).scheme=='https',
                        path=(request.app.state.settings.base_path or '')+'/api/v1/enroll',max_age=3600)
    return {'authenticated':True}


@public.post('/logout')
def logout(request: Request,response: Response):
    browser_origin(request)
    from ..enrollment import digest
    with request.app.state.enrollment.db() as db:
        db.execute('DELETE FROM sessions WHERE secret_hash=?',(digest(request.cookies.get('pool-worker-session','')),))
    response.delete_cookie('pool-worker-session',path=(request.app.state.settings.base_path or '')+'/api/v1/enroll')
    return {'signed_out':True}


@public.post('/device')
def device(body: Device,request: Request):
    return request.app.state.enrollment.begin(body.invitation,body.public_key,body.hostname,body.machine_id)


@public.post('/device-info')
def device_info(body: Code,request: Request):
    browser_origin(request)
    return request.app.state.enrollment.device_info(request.cookies.get('pool-worker-session',''),body.user_code)


@public.post('/authorize')
def authorize(body: Code,request: Request):
    browser_origin(request)
    return request.app.state.enrollment.consent(request.cookies.get('pool-worker-session',''),body.user_code)


@public.post('/token')
def poll(body: Poll,request: Request):
    return request.app.state.enrollment.poll(body.device_code)


@public.get('/vpn-config')
def vpn_config(request: Request):
    return request.app.state.enrollment.configuration(worker_token(request))


@public.post('/cluster-config')
def cluster_config(request: Request):
    return request.app.state.enrollment.cluster_config(worker_token(request))
