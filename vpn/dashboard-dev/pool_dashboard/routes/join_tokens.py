from fastapi import APIRouter, Request
from ..models import NodeRequest
router = APIRouter(prefix='/api/v1/cluster', tags=['join-tokens'])


@router.post('/join-token')
def generate_join_token(body: NodeRequest, request: Request):
    return request.app.state.cluster.join_token(body.node_name)
