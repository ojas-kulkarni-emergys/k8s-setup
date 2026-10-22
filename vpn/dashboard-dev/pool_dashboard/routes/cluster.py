from fastapi import APIRouter, Request
router = APIRouter(prefix='/api/v1/cluster', tags=['cluster'])


@router.get('/nodes')
def nodes(request: Request):
    return {'nodes': request.app.state.cluster.nodes()}
