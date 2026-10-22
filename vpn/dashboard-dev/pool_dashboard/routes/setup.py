from fastapi import APIRouter, Request
from ..models import JoinRequest, CreateCluster
from pydantic import BaseModel, Field
from ..command_preview import CommandPreview
router = APIRouter(prefix='/api/v1/setup', tags=['setup-wizard'])


class PreviewRequest(BaseModel):
    action: str = Field(max_length=100)
    inputs: dict[str, str] = Field(default_factory=dict, max_length=100)


@router.get('/command-routes')
def command_routes(request: Request):
    return {'routes': CommandPreview(request.app.state.settings).routes()}


@router.post('/command-preview')
def command_preview(body: PreviewRequest, request: Request):
    return CommandPreview(request.app.state.settings, body.inputs).preview(body.action)


@router.post('/join')
def join(body: JoinRequest, request: Request):
    return request.app.state.cluster.join_plan(body)


@router.post('/create')
def create(body: CreateCluster, request: Request):
    return request.app.state.cluster.create_plan(body)


@router.get('/modules')
def modules(request: Request):
    root = request.app.state.settings.scripts_root
    paths = ('main.sh', 'k8s/cluster/setup-control-plane.sh', 'k8s/cluster/setup-worker.sh',
             'k8s/cluster/vpn_manager.sh')
    return {'modules': [{'path': p, 'available': (root / p).is_file()} for p in paths],
            'mode': 'plan-only', 'note': 'Existing modules are referenced, never edited or executed by this prototype.'}
