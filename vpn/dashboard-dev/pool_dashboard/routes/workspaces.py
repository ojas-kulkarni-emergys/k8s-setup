"""User dashboard access never grants host-admin or Kubernetes mutation privileges."""
from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel, Field
from ..security import require_admin
from .enrollment import browser_origin, rate_limit

admin=APIRouter(prefix='/api/v1/workspaces',dependencies=[Depends(require_admin)])
public=APIRouter(prefix='/api/v1/enroll/workspace',dependencies=[Depends(rate_limit)])

class Invitation(BaseModel):
    email: str=Field(pattern=r'^[^\s@]+@[^\s@]+\.[^\s@]+$',max_length=254)
    cluster_id: str=Field(pattern=r'^[a-z0-9][a-z0-9-]{0,63}$')
    role: str=Field(default='viewer',pattern=r'^(owner|viewer)$')

class Accept(BaseModel):
    invitation: str=Field(min_length=32,max_length=128)

class Register(Accept):
    email: str=Field(pattern=r'^[^\s@]+@[^\s@]+\.[^\s@]+$',max_length=254)
    password: str=Field(min_length=12,max_length=256)

class Revoke(BaseModel):
    email: str=Field(min_length=3,max_length=254)
    cluster_id: str


def user(request):
    return request.app.state.workspaces.user(request.cookies.get('pool-worker-session',''))

@admin.get('/clusters')
def clusters(request: Request):
    return {'clusters':request.app.state.workspaces.listing(),'local_cluster':request.app.state.settings.cluster_id}

@admin.get('/clusters/{cluster_id}/nodes')
def admin_nodes(cluster_id: str,request: Request):
    return request.app.state.workspaces.nodes(cluster_id)

@admin.post('/invitations')
def invite(body: Invitation,request: Request):
    return request.app.state.workspaces.invite(body.email,body.cluster_id,body.role)

@admin.post('/revoke-membership')
def revoke(body: Revoke,request: Request):
    with request.app.state.enrollment.db() as db:
        db.execute('DELETE FROM cluster_memberships WHERE email=? AND cluster_id=?',(body.email.lower(),body.cluster_id))
        db.execute("UPDATE workspace_invites SET state='revoked' WHERE email=? AND cluster_id=?",(body.email.lower(),body.cluster_id))
    return {'revoked':True,'note':'Dashboard access removed; VPN and Kubernetes machine membership are separate.'}

@public.get('/me')
def me(request: Request):
    return request.app.state.workspaces.listing(user(request))

@public.get('/clusters/{cluster_id}/nodes')
def nodes(cluster_id: str,request: Request):
    return request.app.state.workspaces.nodes(cluster_id,user(request))

@public.post('/register')
def register(body: Register,request: Request):
    browser_origin(request)
    return request.app.state.workspaces.register(body.invitation,body.email,body.password)

@public.post('/accept')
def accept(body: Accept,request: Request):
    browser_origin(request)
    return request.app.state.workspaces.accept(body.invitation,user(request))

@public.post('/invitations')
def owner_invite(body: Invitation,request: Request):
    browser_origin(request)
    return request.app.state.workspaces.invite(body.email,body.cluster_id,body.role,actor=user(request))
