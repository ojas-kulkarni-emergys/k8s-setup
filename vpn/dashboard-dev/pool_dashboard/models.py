import ipaddress
from pydantic import BaseModel, Field, field_validator


class NodeRequest(BaseModel):
    node_name: str = Field(pattern=r'^[a-z0-9](?:[a-z0-9.-]{0,61}[a-z0-9])?$')


class JoinRequest(NodeRequest):
    token: str = Field(min_length=1, max_length=16384)
    address: str

    @field_validator('token')
    @classmethod
    def token_single_line(cls, value):
        if any(c.isspace() or ord(c) < 32 for c in value):
            raise ValueError('Token must be a single uninterrupted string')
        return value

    @field_validator('address')
    @classmethod
    def valid_address(cls, value):
        address = ipaddress.ip_address(value)
        if address.is_loopback or address.is_unspecified or address.is_multicast:
            raise ValueError('Use the worker address reachable by the control plane')
        return str(address)


class CreateCluster(NodeRequest):
    address: str

    _validate_address = field_validator('address')(JoinRequest.valid_address.__func__)


class NetworkRequest(BaseModel):
    name: str = Field(pattern=r'^[a-z0-9][a-z0-9-]{0,31}$')


class MemberRequest(BaseModel):
    email: str = Field(pattern=r'^[^\s@]+@[^\s@]+\.[^\s@]+$', max_length=254)
