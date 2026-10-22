"""Local admin access, without cookies or a reusable token in browser storage."""
import secrets
from fastapi import HTTPException, Request


def require_admin(request: Request):
    header = request.headers.get('Authorization', '')
    if not header.startswith('Bearer ') or not secrets.compare_digest(
            header[7:], request.app.state.access_token):
        raise HTTPException(401, 'Enter the local dashboard access token.')
