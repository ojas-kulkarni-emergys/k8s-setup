from fastapi import APIRouter, Request
from ..models import JoinRequest

router = APIRouter(prefix='/api/v1/remote', tags=['ssh-workers'])


@router.get('/targets')
def targets(request: Request):
    settings = request.app.state.settings
    return {'enabled': settings.remote_execution_enabled,
            'targets': [{'name': name, 'host': target.get('host')} for name, target in settings.ssh_targets.items()]}


@router.post('/targets/{name}/check')
def check(name: str, request: Request):
    return request.app.state.remote.check(name)


@router.post('/targets/{name}/join', status_code=202)
def join(name: str, body: JoinRequest, request: Request):
    return request.app.state.remote.start(name, body)


@router.get('/jobs/{job_id}')
def job(job_id: str, request: Request):
    return request.app.state.remote.get(job_id)
