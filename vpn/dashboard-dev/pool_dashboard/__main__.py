import uvicorn
from .app import create_app
from .settings import Settings

if __name__ == '__main__':
    settings = Settings.load()
    app = create_app(settings)
    print('Local development dashboard: http://127.0.0.1:8090'+settings.base_path+'/')
    print('Read the access token locally from:', settings.state_dir / 'access-token')
    uvicorn.run(app, host='127.0.0.1', port=8090)
