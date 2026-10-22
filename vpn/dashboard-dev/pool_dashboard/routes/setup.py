from fastapi import APIRouter, Request
from ..models import JoinRequest, CreateCluster
router = APIRouter(prefix='/api/v1/setup', tags=['setup-wizard'])


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
