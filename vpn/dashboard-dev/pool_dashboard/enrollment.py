"""Invitation-bound device authorization. No worker receives the admin credential."""
import base64
import hashlib
import hmac
import ipaddress
import secrets
import shlex
import sqlite3
import subprocess
import time
from urllib.parse import urlparse
from contextlib import contextmanager
from fastapi import HTTPException


def digest(value):
    return hashlib.sha256(value.encode()).hexdigest()


def public_key(value):
    try:
        if len(base64.b64decode(value, validate=True)) != 32:
            raise ValueError()
    except (ValueError, TypeError):
        raise HTTPException(422, 'Use a base64-encoded 32-byte WireGuard public key.')
    return value


class Enrollment:
    def __init__(self, settings, networks, cluster, runner=subprocess.run):
        self.settings, self.networks, self.cluster, self.runner = settings, networks, cluster, runner
        self.path = settings.state_dir / 'enrollment.sqlite3'
        with self.db() as db:
            db.executescript('''
                CREATE TABLE IF NOT EXISTS invites (
                  id TEXT PRIMARY KEY, secret_hash TEXT UNIQUE NOT NULL,
                  email TEXT NOT NULL, node_name TEXT NOT NULL, network TEXT NOT NULL,
                  expires REAL NOT NULL, state TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS users (
                  email TEXT PRIMARY KEY, salt BLOB NOT NULL, password_hash BLOB NOT NULL);
                CREATE TABLE IF NOT EXISTS sessions (
                  secret_hash TEXT PRIMARY KEY, email TEXT NOT NULL, expires REAL NOT NULL);
                CREATE TABLE IF NOT EXISTS devices (
                  secret_hash TEXT PRIMARY KEY, user_code TEXT UNIQUE NOT NULL,
                  invite TEXT UNIQUE NOT NULL, public_key TEXT UNIQUE NOT NULL,
                  expires REAL NOT NULL, state TEXT NOT NULL, address TEXT UNIQUE,
                  access_hash TEXT UNIQUE, join_state TEXT NOT NULL DEFAULT 'unused',
                  FOREIGN KEY(invite) REFERENCES invites(id));
            ''')
        self.path.chmod(0o600)

    @contextmanager
    def db(self):
        db = sqlite3.connect(self.path, timeout=10)
        db.row_factory = sqlite3.Row
        db.execute('PRAGMA foreign_keys=ON')
        try:
            with db: yield db
        finally: db.close()

    def enabled(self):
        if not self.settings.enrollment_enabled:
            raise HTTPException(409, 'Worker enrollment is disabled in dashboard config.yaml.')
        url = urlparse(self.settings.public_url)
        if not url.hostname or url.username or url.password or url.query or url.fragment:
            raise HTTPException(409,'Configure a plain dashboard public_url without credentials, query or fragment.')
        if url.scheme != 'https' and url.hostname not in ('127.0.0.1', 'localhost'):
            raise HTTPException(409, 'Public worker enrollment requires HTTPS.')

    def create_invite(self, email, node_name, network, minutes=60):
        self.enabled()
        if network not in {n['name'] for n in self.networks.list()}:
            raise HTTPException(404, 'Network does not exist.')
        if any(n['name'] == node_name for n in self.cluster.nodes()):
            raise HTTPException(409, 'Node is already registered.')
        token, invite_id = secrets.token_urlsafe(32), secrets.token_hex(8)
        expires = time.time() + minutes * 60
        with self.db() as db:
            db.execute('INSERT INTO invites VALUES (?,?,?,?,?,?,?)',
                       (invite_id, digest(token), email.lower(), node_name, network, expires, 'fresh'))
        base = self.settings.public_url
        command = ('curl --fail --show-error --silent ' + shlex.quote(base+'/join.sh')
                   + ' -o join.sh && bash join.sh --server ' + shlex.quote(base)
                   + ' --invite ' + shlex.quote(token))
        return {'id': invite_id, 'invitation_code': token, 'expires': expires,
                'link': base+'/join/#invite='+token, 'command': command,
                'note': 'Default is preview. Add --execute to authorize local worker changes. Inspect join.sh before running.'}

    def invite(self, db, token, fresh=False):
        row = db.execute('SELECT * FROM invites WHERE secret_hash=?', (digest(token),)).fetchone()
        if not row or row['expires'] <= time.time() or row['state']=='revoked':
            raise HTTPException(403, 'Invitation invalid, expired or revoked.')
        if fresh and row['state']!='fresh':
            raise HTTPException(409, 'Invitation is already bound to a device.')
        return row

    def register(self, invitation, email, password):
        self.enabled()
        salt = secrets.token_bytes(16)
        hashed = hashlib.scrypt(password.encode(), salt=salt, n=16384, r=8, p=1)
        with self.db() as db:
            invite = self.invite(db, invitation)
            if not hmac.compare_digest(invite['email'], email.lower()):
                raise HTTPException(403, 'Account must match the invited email.')
            try:
                db.execute('INSERT INTO users VALUES (?,?,?)', (email.lower(), salt, hashed))
            except sqlite3.IntegrityError:
                raise HTTPException(409, 'Account already exists. Sign in instead.')
        return {'created': True}

    def login(self, email, password):
        with self.db() as db:
            user = db.execute('SELECT * FROM users WHERE email=?', (email.lower(),)).fetchone()
            salt = user['salt'] if user else b'unknown-user-salt'
            hashed = hashlib.scrypt(password.encode(), salt=salt, n=16384, r=8, p=1)
            if not user or not hmac.compare_digest(user['password_hash'], hashed):
                raise HTTPException(401, 'Invalid email or password.')
            token = secrets.token_urlsafe(32)
            db.execute('DELETE FROM sessions WHERE expires<?', (time.time(),))
            db.execute('INSERT INTO sessions VALUES (?,?,?)', (digest(token), user['email'], time.time()+3600))
        return token

    def begin(self, invitation, key, hostname=None, machine_id=None):
        self.enabled(); public_key(key)
        token = secrets.token_urlsafe(32)
        code = secrets.token_hex(4).upper()
        with self.db() as db:
            db.execute('BEGIN IMMEDIATE')
            invite = self.invite(db, invitation, fresh=True)
            if hostname is not None and hostname != invite['node_name']:
                raise HTTPException(409, 'Worker hostname does not match this invitation. Ask the administrator to invite the actual worker hostname: '+hostname)
            if not machine_id:
                raise HTTPException(422,'Use the latest join.sh: a machine fingerprint is required.')
            assignment=db.execute('SELECT * FROM machine_assignments WHERE fingerprint=?',(machine_id,)).fetchone()
            if assignment:
                raise HTTPException(409,'This machine already has a cluster role. Use another machine; cross-cluster role changes are disabled.')
            db.execute('INSERT INTO machine_assignments VALUES (?,?,?,?,?)',
                       (machine_id,hostname or invite['node_name'],self.settings.cluster_id,'worker',invite['email']))
            expires = min(time.time()+900, invite['expires'])
            try:
                db.execute('INSERT INTO devices (secret_hash,user_code,invite,public_key,expires,state) VALUES (?,?,?,?,?,?)',
                           (digest(token), code, invite['id'], key, expires, 'pending'))
            except sqlite3.IntegrityError:
                raise HTTPException(409, 'This invitation or public key is already registered.')
            db.execute('UPDATE invites SET state=? WHERE id=?', ('claimed', invite['id']))
        return {'device_code': token, 'user_code': code, 'interval': 5, 'expires_in': max(0,int(expires-time.time())),
                'verification_uri': self.settings.public_url+'/device/',
                'verification_uri_complete': self.settings.public_url+'/device/#code='+code}

    def consent(self, session, code):
        self.enabled()
        with self.db() as db:
            db.execute('BEGIN IMMEDIATE')
            user = db.execute('SELECT email FROM sessions WHERE secret_hash=? AND expires>?',
                              (digest(session),time.time())).fetchone()
            if not user: raise HTTPException(401,'Sign in before authorizing the device.')
            device = db.execute('SELECT d.*,i.email,i.state AS invite_state FROM devices d JOIN invites i ON i.id=d.invite WHERE user_code=?', (code,)).fetchone()
            if not device or device['expires']<=time.time() or device['state']!='pending' or device['invite_state']=='revoked':
                raise HTTPException(409,'Device request expired or is not awaiting authentication.')
            if not hmac.compare_digest(user['email'],device['email']):
                raise HTTPException(403,'This invitation belongs to a different account.')
            db.execute("UPDATE devices SET state='authenticated' WHERE user_code=?",(code,))
        return {'state':'authenticated', 'note':'Waiting for administrator peer approval.'}

    def device_info(self, session, code):
        self.enabled()
        with self.db() as db:
            user=db.execute('SELECT email FROM sessions WHERE secret_hash=? AND expires>?',(digest(session),time.time())).fetchone()
            row=db.execute('SELECT d.user_code,d.public_key,d.state,d.expires,i.email,i.node_name,i.network FROM devices d JOIN invites i ON i.id=d.invite WHERE d.user_code=?',(code,)).fetchone()
        if not user: raise HTTPException(401,'Sign in first.')
        if not row or row['expires']<=time.time() or row['email']!=user['email']:
            raise HTTPException(403,'Device unavailable for this account.')
        return dict(row)

    def list(self):
        with self.db() as db:
            return [dict(row) for row in db.execute('''SELECT d.user_code,d.public_key,d.address,d.state,d.expires,
                i.id AS invitation_id,i.email,i.node_name,i.network FROM devices d JOIN invites i ON i.id=d.invite ORDER BY d.expires DESC LIMIT 100''')]

    def invitations(self):
        with self.db() as db:
            return [dict(row) for row in db.execute('SELECT id,email,node_name,network,expires,state FROM invites ORDER BY expires DESC LIMIT 100')]

    def wg(self, args):
        interface = self.settings.wireguard.get('interface','pool0')
        if not __import__('re').fullmatch(r'pool[0-9]{1,2}',interface):
            raise HTTPException(409,'Use a dedicated dashboard-managed pool0..pool99 interface.')
        try:
            result=self.runner(['sudo','-n','/usr/local/sbin/pool-wireguard',*args], capture_output=True,text=True,check=True,timeout=15)
        except (OSError,subprocess.SubprocessError):
            raise HTTPException(503,'WireGuard operation failed. Check the dedicated hub and its constrained sudo permissions.')
        return result.stdout.strip()

    def approve(self, code, apply=False):
        self.enabled()
        settings=self.settings.wireguard
        interface=settings.get('interface','pool0')
        with self.db() as db:
            db.execute('BEGIN IMMEDIATE')
            row=db.execute('SELECT d.*,i.network,i.state AS invite_state FROM devices d JOIN invites i ON i.id=d.invite WHERE user_code=?',(code,)).fetchone()
            if not row or row['expires']<=time.time() or row['state']!='authenticated' or row['invite_state']=='revoked':
                raise HTTPException(409,'Device must authenticate before peer approval.')
            network=next(n for n in self.networks.list() if n['name']==row['network'])
            used={r[0] for r in db.execute('SELECT address FROM devices WHERE address IS NOT NULL')}
            used.add(settings.get('server_address','10.210.0.1'))
            address=next((str(a) for a in ipaddress.ip_network(network['subnet']).hosts() if str(a) not in used),None)
            if not address: raise HTTPException(409,'Network address pool exhausted.')
            command=shlex.join(['sudo','wg','set',interface,'peer',row['public_key'],'allowed-ips',address+'/32'])
            if not apply:
                return {'mode':'preview','address':address,'commands':[command,shlex.join(['sudo','wg-quick','save',interface])],
                        'note':'No peer applied. Logical group membership alone does not enforce isolation.'}
            if not settings.get('apply_peers') or not settings.get('endpoint'):
                raise HTTPException(409,'Configure the WireGuard UDP endpoint and enable apply_peers first.')
            public_key(self.wg(['wg','show',interface,'public-key']))
            existing=self.wg(['wg','show',interface,'allowed-ips'])
            if row['public_key'] in existing or address+'/32' in existing.split():
                raise HTTPException(409,'Public key/address already exists on the hub. Review it before applying.')
            self.wg(['wg','set',interface,'peer',row['public_key'],'allowed-ips',address+'/32'])
            try: self.wg(['wg-quick','save',interface])
            except HTTPException:
                self.wg(['wg','set',interface,'peer',row['public_key'],'remove'])
                raise
            db.execute("UPDATE devices SET state='approved',address=? WHERE user_code=?",(address,code))
            email=db.execute('SELECT email FROM invites WHERE id=?',(row['invite'],)).fetchone()['email']
            db.execute("INSERT OR IGNORE INTO cluster_memberships VALUES (?,?,?)",(email,self.settings.cluster_id,'worker'))
        return {'state':'approved','address':address}

    def poll(self, device_code):
        self.enabled()
        with self.db() as db:
            db.execute('BEGIN IMMEDIATE')
            row=db.execute('SELECT d.*,i.state AS invite_state FROM devices d JOIN invites i ON i.id=d.invite WHERE d.secret_hash=?',(digest(device_code),)).fetchone()
            if not row or row['expires']<=time.time() or row['invite_state']=='revoked':
                raise HTTPException(403,'Device request expired or revoked.')
            if row['state'] not in ('approved','connected'):
                return {'state':row['state'],'interval':5}
            token=secrets.token_urlsafe(32)
            db.execute('UPDATE devices SET access_hash=? WHERE secret_hash=?',(digest(token),row['secret_hash']))
        return {'state':'approved','access_token':token,'expires_in':max(0,int(row['expires']-time.time()))}

    def worker(self, token):
        self.enabled()
        with self.db() as db:
            row=db.execute('SELECT d.*,i.node_name,i.network,i.state AS invite_state FROM devices d JOIN invites i ON i.id=d.invite WHERE access_hash=?',(digest(token),)).fetchone()
        if not row or row['expires']<=time.time() or row['invite_state']=='revoked' or row['state'] not in ('approved','connected'):
            raise HTTPException(401,'Worker authorization expired, unavailable or revoked.')
        return row

    def configuration(self, token):
        row=self.worker(token); settings=self.settings.wireguard
        interface=settings.get('interface','pool0')
        return {'address':row['address']+'/32','public_key':public_key(self.wg(['wg','show',interface,'public-key'])),
                'endpoint':settings['endpoint'],'allowed_ips':settings.get('allowed_ips',self.settings.vpn_pool),
                'server_address':settings['server_address'],'node_name':row['node_name'], 'interface':'pool0'}

    def cluster_config(self, token):
        row=self.worker(token); interface=self.settings.wireguard.get('interface','pool0')
        handshakes=self.wg(['wg','show',interface,'latest-handshakes'])
        last=next((int(parts[1]) for line in handshakes.splitlines() if len(parts:=line.split())==2 and parts[0]==row['public_key']),0)
        if last<=0 or not 0<=time.time()-last<180:
            raise HTTPException(409,'Connect WireGuard and ping the hub first; no recent authenticated handshake exists.')
        with self.db() as db:
            db.execute('BEGIN IMMEDIATE')
            # Reserve issuance atomically, before the external token operation.
            updated=db.execute("UPDATE devices SET join_state='issuing',state='connected' WHERE secret_hash=? AND join_state='unused'",(row['secret_hash'],))
            if not updated.rowcount: raise HTTPException(409,'Join token was already requested. An administrator must review retries.')
        try:
            generated=self.cluster.join_token(row['node_name'])
        except HTTPException:
            # Ambiguous failures may have created a token; never retry automatically.
            raise HTTPException(503,'Token generation failed. Administrator review is required before retrying.')
        with self.db() as db:
            db.execute("UPDATE devices SET join_state='issued' WHERE secret_hash=?",(row['secret_hash'],))
        return {'node_name':row['node_name'],'address':row['address'],'channel':self.settings.snap_channel,'token':generated['token']}

    def revoke(self, invite_id):
        with self.db() as db:
            db.execute('BEGIN IMMEDIATE')
            invite=db.execute('SELECT * FROM invites WHERE id=?',(invite_id,)).fetchone()
            if not invite: raise HTTPException(404,'Invitation not found.')
            device=db.execute('SELECT * FROM devices WHERE invite=?',(invite_id,)).fetchone()
            if device and device['state'] in ('approved','connected'):
                if not self.settings.wireguard.get('apply_peers'):
                    raise HTTPException(409,'Re-enable peer operations to remove this applied peer.')
                interface=self.settings.wireguard.get('interface','pool0')
                self.wg(['wg','set',interface,'peer',device['public_key'],'remove'])
                self.wg(['wg-quick','save',interface])
            db.execute("UPDATE invites SET state='revoked' WHERE id=?",(invite_id,))
            remaining=db.execute("""SELECT 1 FROM devices d JOIN invites i ON i.id=d.invite
                WHERE i.email=? AND i.state!='revoked' AND d.state IN ('approved','connected') LIMIT 1""",(invite['email'],)).fetchone()
            if not remaining:
                db.execute("DELETE FROM cluster_memberships WHERE email=? AND cluster_id=? AND role='worker'",
                           (invite['email'],self.settings.cluster_id))
        return {'revoked':True,'note':'Revokes enrollment/VPN access, not an already joined Kubernetes node or issued Kubernetes credential.'}
