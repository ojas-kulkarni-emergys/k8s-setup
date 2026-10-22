"""Local-only prototype. Run on the control-plane host without modifying main.sh."""
import os
import secrets
from pathlib import Path
from fastapi import Depends, FastAPI
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from .settings import Settings
from .security import require_admin
from .services import ClusterService, NetworkStore
from .routes import cluster, join_tokens, setup, vpn, remote
from .remote import RemoteWorkers

STATIC = Path(__file__).parent / 'static'


def create_app(settings=None, runner=None, token=None):
    settings = settings or Settings.load()
    settings.state_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    settings.state_dir.chmod(0o700)
    token_path = settings.state_dir / 'access-token'
    if token is None:
        if not token_path.exists():
            fd = os.open(token_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, 'w') as stream:
                stream.write(secrets.token_urlsafe(32))
        token_path.chmod(0o600)
        token = token_path.read_text().strip()
        if len(token) < 32:
            raise RuntimeError('Dashboard access token must have at least 32 characters')
    application = FastAPI(title='Office Inference Pool — Development Console', docs_url=None, redoc_url=None, openapi_url=None)
    application.state.settings = settings
    application.state.access_token = token
    application.state.cluster = ClusterService(settings, **({'runner': runner} if runner else {}))
    application.state.networks = NetworkStore(settings)
    application.state.remote = RemoteWorkers(settings, application.state.cluster)
    for router in (cluster.router, join_tokens.router, setup.router, vpn.router, remote.router):
        application.include_router(router, dependencies=[Depends(require_admin)])

    @application.middleware('http')
    async def private_responses(request, call_next):
        response = await call_next(request)
        response.headers['Cache-Control'] = 'no-store'
        response.headers['X-Content-Type-Options'] = 'nosniff'
        response.headers['Content-Security-Policy'] = "default-src 'self'; script-src 'self'; style-src 'self'; frame-ancestors 'none'"
        return response

    @application.get('/')
    def dashboard():
        return FileResponse(STATIC / 'index.html')

    application.mount('/static', StaticFiles(directory=STATIC), name='static')
    return application
