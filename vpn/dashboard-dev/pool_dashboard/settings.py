from dataclasses import dataclass, field
from pathlib import Path
import yaml


@dataclass
class Settings:
    state_dir: Path
    scripts_root: Path
    command_prefix: list[str]
    allow_token_generation: bool = False
    snap_channel: str = "1.35-classic/stable"
    vpn_pool: str = "10.210.0.0/16"
    reserved_cidrs: tuple[str, ...] = ()
    remote_execution_enabled: bool = False
    ssh_targets: dict = field(default_factory=dict)
    base_path: str = ''
    public_url: str = 'http://127.0.0.1:8090'
    enrollment_enabled: bool = False
    wireguard: dict = field(default_factory=dict)
    cluster_id: str = 'local'
    cluster_name: str = 'Office inference pool'
    cluster_connections: list = field(default_factory=list)

    @classmethod
    def load(cls, path=None):
        path = Path(path or Path(__file__).resolve().parents[1] / 'config.yaml').resolve()
        with path.open() as stream:
            data = yaml.safe_load(stream)
        return cls(state_dir=(path.parent / data['state_dir']).resolve(),
                   scripts_root=(path.parent / data['scripts_root']).resolve(),
                   command_prefix=list(data['command_prefix']),
                   allow_token_generation=data.get('allow_token_generation', False) is True,
                   snap_channel=data['snap_channel'], vpn_pool=data['vpn_pool'],
                   reserved_cidrs=tuple(data.get('reserved_cidrs', [])),
                   remote_execution_enabled=data.get('remote_execution_enabled', False) is True,
                   ssh_targets=data.get('ssh_targets', {}),
                   base_path=data.get('base_path', '').rstrip('/'),
                   public_url=data.get('public_url', 'http://127.0.0.1:8090').rstrip('/'),
                   enrollment_enabled=data.get('enrollment_enabled', False) is True,
                   wireguard=data.get('wireguard', {}),cluster_id=data.get('cluster_id','local'),
                   cluster_name=data.get('cluster_name','Office inference pool'),
                   cluster_connections=data.get('cluster_connections',[]))
