from fastapi import APIRouter, Request
from ..models import NetworkRequest, MemberRequest
router = APIRouter(prefix='/api/v1/vpn', tags=['vpn-development'])


@router.get('/networks')
def networks(request: Request):
    return {'networks': request.app.state.networks.list(), 'enforcement': 'not implemented'}


@router.post('/networks', status_code=201)
def create_network(body: NetworkRequest, request: Request):
    return request.app.state.networks.create(body.name)


@router.post('/networks/{name}/members')
def add_member(name: str, body: MemberRequest, request: Request):
    return request.app.state.networks.member(name, body.email)


@router.delete('/networks/{name}/members')
def remove_member(name: str, body: MemberRequest, request: Request):
    return request.app.state.networks.member(name, body.email, remove=True)
