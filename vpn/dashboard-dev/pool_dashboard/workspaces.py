"""Account memberships and machine assignments, separate from VPN peer identity."""
import hashlib
import hmac
import secrets
import re
import time
from dataclasses import replace
from pathlib import Path
from fastapi import HTTPException
from .enrollment import digest
from .services import ClusterService


def machine_fingerprint():
    path=Path('/etc/machine-id')
    if not path.is_file() or not path.read_text().strip():
        raise RuntimeError('A stable /etc/machine-id is required for machine role tracking.')
    return hashlib.sha256(('pool-machine-v1\n'+path.read_text().strip()).encode()).hexdigest()


class Workspaces:
    def __init__(self,settings,enrollment,cluster,runner=None):
        self.settings,self.enrollment=settings,enrollment
        for cid in [settings.cluster_id,*[item['id'] for item in settings.cluster_connections]]:
            if not re.fullmatch(r'[a-z0-9][a-z0-9-]{0,63}',cid):
                raise ValueError('Use stable lowercase cluster IDs containing letters, digits or hyphens.')
        self.clusters={settings.cluster_id:{'id':settings.cluster_id,'name':settings.cluster_name,'local':True}}
        self.services={settings.cluster_id:cluster}
        for item in settings.cluster_connections:
            cid=item['id']
            if cid in self.clusters:raise ValueError('Duplicate cluster id: '+cid)
            self.clusters[cid]={'id':cid,'name':item['name'],'local':False}
            # Only operator-reviewed config can supply commands, never browser input.
            if item.get('command_prefix'):
                self.services[cid]=ClusterService(replace(settings,command_prefix=item['command_prefix']),**({'runner':runner} if runner else {}))
        with enrollment.db() as db:
            first_upgrade=not db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='cluster_memberships'").fetchone()
            db.executescript('''
                CREATE TABLE IF NOT EXISTS cluster_memberships (
                    email TEXT NOT NULL,cluster_id TEXT NOT NULL,role TEXT NOT NULL,
                    PRIMARY KEY(email,cluster_id));
                CREATE TABLE IF NOT EXISTS workspace_invites (
                    id TEXT PRIMARY KEY,secret_hash TEXT UNIQUE NOT NULL,email TEXT NOT NULL,
                    cluster_id TEXT NOT NULL,role TEXT NOT NULL,expires REAL NOT NULL,state TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS machine_assignments (
                    fingerprint TEXT PRIMARY KEY,hostname TEXT NOT NULL,cluster_id TEXT NOT NULL,
                    role TEXT NOT NULL,email TEXT NOT NULL);
            ''')
            # One-time migration; never restore explicitly revoked account access.
            if first_upgrade:
                db.execute("""INSERT OR IGNORE INTO cluster_memberships
                    SELECT DISTINCT i.email,?,'worker' FROM devices d JOIN invites i ON i.id=d.invite
                    WHERE d.state IN ('approved','connected') AND i.state!='revoked'""",(settings.cluster_id,))
            fingerprint=machine_fingerprint()
            current=db.execute('SELECT * FROM machine_assignments WHERE fingerprint=?',(fingerprint,)).fetchone()
            if current and (current['cluster_id']!=settings.cluster_id or current['role']!='control-plane'):
                raise RuntimeError('This dashboard host is already assigned to another cluster/role.')
            import socket
            db.execute('INSERT OR IGNORE INTO machine_assignments VALUES (?,?,?,?,?)',
                       (fingerprint,socket.gethostname().lower(),settings.cluster_id,'control-plane',''))

    def user(self,session):
        with self.enrollment.db() as db:
            row=db.execute('SELECT email FROM sessions WHERE secret_hash=? AND expires>?',(digest(session),time.time())).fetchone()
        if not row:raise HTTPException(401,'Sign in to your user account.')
        return row['email']

    def membership(self,email,cluster_id):
        with self.enrollment.db() as db:
            row=db.execute('SELECT role FROM cluster_memberships WHERE email=? AND cluster_id=?',(email,cluster_id)).fetchone()
        if cluster_id not in self.clusters or not row:raise HTTPException(403,'You are not a member of this cluster.')
        return row['role']

    def listing(self,email=None):
        if email is None:return [dict(c,role='administrator') for c in self.clusters.values()]
        with self.enrollment.db() as db:
            memberships={r['cluster_id']:r['role'] for r in db.execute('SELECT * FROM cluster_memberships WHERE email=?',(email,))}
            machines=[dict(r) for r in db.execute('SELECT hostname,cluster_id,role,fingerprint FROM machine_assignments WHERE email=?',(email,))]
        return {'email':email,'clusters':[dict(c,role=memberships[cid]) for cid,c in self.clusters.items() if cid in memberships],
                'machines':machines,'local_cluster':self.settings.cluster_id}

    def nodes(self,cluster_id,email=None):
        if email is not None:self.membership(email,cluster_id)
        if cluster_id not in self.clusters:raise HTTPException(404,'Unknown cluster.')
        if cluster_id not in self.services:raise HTTPException(409,'Configure this cluster inventory connection on the dashboard host first.')
        return {'cluster':self.clusters[cluster_id],'nodes':self.services[cluster_id].nodes()}

    def invite(self,email,cluster_id,role,actor=None):
        if cluster_id not in self.clusters:raise HTTPException(404,'Unknown cluster.')
        if actor is not None and (self.membership(actor,cluster_id)!='owner' or role!='viewer'):
            raise HTTPException(403,'Cluster owners can invite viewers to their own clusters.')
        token=secrets.token_urlsafe(32);iid=secrets.token_hex(8)
        with self.enrollment.db() as db:
            db.execute('INSERT INTO workspace_invites VALUES (?,?,?,?,?,?,?)',
                       (iid,digest(token),email.lower(),cluster_id,role,time.time()+86400,'fresh'))
        return {'id':iid,'code':token,'link':self.settings.public_url+'/account/#invite='+token,
                'note':'Account access invitation, valid for 24 hours. Does not join or reassign a machine.'}

    def invitation(self,db,token,email):
        row=db.execute('SELECT * FROM workspace_invites WHERE secret_hash=?',(digest(token),)).fetchone()
        if not row or row['state']!='fresh' or row['expires']<time.time() or not hmac.compare_digest(row['email'],email.lower()):
            raise HTTPException(403,'Account invitation invalid, expired or belongs to another email.')
        return row

    def register(self,token,email,password):
        salt=secrets.token_bytes(16)
        hashed=hashlib.scrypt(password.encode(),salt=salt,n=16384,r=8,p=1)
        with self.enrollment.db() as db:
            self.invitation(db,token,email)
            if db.execute('SELECT 1 FROM users WHERE email=?',(email.lower(),)).fetchone():
                raise HTTPException(409,'Account already exists. Sign in and accept the invitation instead.')
            db.execute('INSERT INTO users VALUES (?,?,?)',(email.lower(),salt,hashed))
        return {'created':True}

    def accept(self,token,email):
        with self.enrollment.db() as db:
            db.execute('BEGIN IMMEDIATE')
            row=self.invitation(db,token,email)
            db.execute('''INSERT INTO cluster_memberships VALUES (?,?,?) ON CONFLICT(email,cluster_id)
                       DO UPDATE SET role=CASE WHEN cluster_memberships.role='owner' THEN 'owner' ELSE excluded.role END''',
                       (email,row['cluster_id'],row['role']))
            db.execute("UPDATE workspace_invites SET state='accepted' WHERE id=?",(row['id'],))
            if row['role']=='owner' and row['cluster_id']==self.settings.cluster_id:
                db.execute("UPDATE machine_assignments SET email=? WHERE fingerprint=? AND email=''",(email,machine_fingerprint()))
        return {'joined':True,'cluster_id':row['cluster_id']}
