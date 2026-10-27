# Pool Console — isolated development prototype

Local dashboard for an office-wide Canonical Kubernetes inference pool. Kept under
`vpn/dashboard-dev` because the VPN control plane is experimental. Existing main.sh,
cluster scripts, VPN installers, config.yaml and active ingress are not modified.

The current priority deployment is reverse-kt; see its `deploy/canonical/README.md`.
Nothing in this dashboard builds images, deploys reverse-kt, or rewrites WireGuard.
Optional SSH worker execution is now available, disabled by default; see below.

## Commands-only source walkthrough

Open **main.sh walkthrough** in the dashboard. Its route dropdown is read from the
`dispatch()` case in the repository's `main.sh`; there is no server-side command
catalog for this screen. Select a route, follow submenu questions, and reveal
commands one at a time. Each command includes its source filename/line and a copy
button. Config reads such as `$(cfg headlamp.namespace)`, shell assignments, script
paths, function arguments and supplied answers are resolved into the displayed
command. Editing a script/config is reflected on the next preview request.

The preview runs **no shell, cluster, SSH, VPN or configuration-writing commands**.
It is independent of the optional SSH executor and the older generated plan API;
their execution/planning behavior is unchanged. The entry-point command is shown
for reference; it may still prompt when run through the CLI. Source commands assume
the CLI's root Bash context on the intended machine. Prerequisite checks appear as
steps; do not continue if a check fails. Function-only failure handlers containing
`return` are not included in the copied prerequisite command.

Values that depend on runtime command output or filesystem/network checks cannot
be inferred accurately from files alone. The walkthrough asks for that result or
branch instead of executing a probe or guessing. Answers stay in browser memory
and are sent only to the authenticated, no-store preview API. They do not change
config.yaml. Secrets may appear in resolved commands; clear the preview afterwards.

This is a bounded static Bash reader, not a general Bash interpreter. It follows
the repository's conventional function definitions, case routes, menu loops and
script calls. Unsupported constructs (including non-menu loops and complex elif
chains) stop with an explicit limitation; the UI does not claim the route is fully
resolved. Runtime choices still require the operator to verify the actual machine.
Quoted embedded Python heredocs remain intact and are never executed or treated
as shell variable expansions.

- `GET /api/v1/setup/command-routes`: current main.sh action routes.
- `POST /api/v1/setup/command-preview`: selected action and accumulated answers,
  returning source commands, route trace, next question and completeness state.

## Start later on the control-plane host

```bash
cd /home/ojas/hf/k8s-setup/vpn/dashboard-dev
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
.venv/bin/python -m pool_dashboard
```

Or activate that environment and run `bash run-wizard.sh`. It prints the local URL
http://127.0.0.1:8090/pool/. Read `.state/access-token` locally and enter it in the UI.
State/access token files are ignored by Git; don't publish them. The browser holds
the access token in memory, not cookies/localStorage. APIs require a Bearer token;
no wildcard CORS or unauthenticated cluster-mutation endpoints are enabled.

This is a host-side app, not a pod with a privileged socket/host mount. Configure
`command_prefix` in THIS folder's config for access to Canonical `k8s`. By default
it uses the root-owned `pool-k8s` broker; install the reviewed helpers below or inventory returns
an explicit unavailable error. Don't grant a public web service unrestricted sudo.
Keep this prototype loopback-only; office deployment needs SSO, per-user RBAC,
authenticated TLS, audit/rate limits and a constrained privileged broker.

## Screens and routed APIs

- Cluster overview: real node/worker readiness, addresses, CPU/memory and GPU count.
  `GET /api/v1/cluster/nodes`.
- Token generation: `POST /api/v1/cluster/join-token` with `{"node_name":"worker1"}`.
  It uses `k8s get-join-token worker1 --worker` on the control plane. Disabled until
  `allow_token_generation: true` is set in this app's config after privilege review.
- Window-style setup wizard: join with an existing/generated token or create a
  fresh cluster plan. `POST /api/v1/setup/join` and `/api/v1/setup/create`.
  Returns commands for the intended worker/new control-plane machine; NEVER runs
  join/bootstrap on the dashboard host. Optional remote SSH execution is a separate
  explicit action in the Remote workers screen; no worker agent is installed.
- Setup module reference: `GET /api/v1/setup/modules`. The wizard can download a
  per-node config and a command invoking the existing setup-worker/control-plane
  module. This reuses the current script architecture without changing main.sh.
  The target machine needs this repository and the module's prerequisites; adjust
  the displayed repository path if its checkout lives elsewhere on that machine.
  Downloaded configs/scripts may contain join credentials: transfer securely and
  remove after use. Tokens are not persisted in SQLite or server logs.
- VPN workbench: routes under `/api/v1/vpn/networks` and `/networks/{name}/members`.
  Create network records, allocate unique /24 subnets, add/remove members.
  Includes a default company-wide record. THIS IS METADATA ONLY. Network-record routes alone apply no WireGuard peers,
  routing, IP forwarding or iptables changes. Device enrollment is a separate opt-in
  peer-management flow. No logical-network isolation is claimed.

The entire prototype is single-admin; membership records do not implement SSO or
per-user authorization. The prior conversation's plain session-cookie identity and
unvalidated sudo commands are not copied. Multiple WireGuard subnets/interfaces
alone do not ensure isolation: a future executor must enforce firewall/routing,
peer key ownership, unique addresses, expiry, revocation and rollback consistently.

## Example join-plan request

```json
{
  "node_name": "office-worker-01",
  "address": "100.81.95.34",
  "token": "TOKEN_FROM_THE_CONTROL_PLANE"
}
```

The address must belong to the worker and be reachable by the control plane.
Install/authenticate its VPN first. One physical host cannot run independent
Canonical control-plane and worker snap instances just by joining itself again;
use a separate machine/VM if separate nodes are needed. Kubernetes may schedule
regular workloads on the control-plane node already.

Create-cluster plans are for NEW machines. They do not reset/migrate the cluster
hosting the dashboard. Token generation is a membership operation and is opt-in;
if enabled it returns the real token only once per response (no database storage).

## Naming and eventual main.sh integration

Keep `k8s-setup` for now: renaming would break existing absolute paths/docs. If the
project becomes an office platform, `office-inference-pool` describes both the
cluster and shared inference better than `k8s-pooled-inferencing`. The dashboard's
display name can change without renaming the repository.

The launcher is a separate entry point for now. Later a main.sh menu item can
launch this app and open its URL, but that integration is deliberately deferred.
No existing script has been changed to start a server or browser.

## Offline tests

```bash
cd /home/ojas/hf/k8s-setup/vpn/dashboard-dev
PYTHONPATH=. .venv/bin/python -m unittest discover -s tests -v
```

Tests call the ASGI app with mocked host/SSH commands; short sync handlers run inline
in the test harness to avoid test-client portal/thread dependence. No real cluster
commands, secrets, VPN state or firewall rules are modified. Browser rendering is
not verified by the API tests. This folder is not yet a production control plane.

## Execute a worker join over WireGuard + SSH

WireGuard supplies connectivity; OpenSSH executes approved operations over that
connection. The same mechanism works over Tailscale or a trusted LAN. This feature
does not install/configure a VPN or apply VPN workbench membership records.

On the worker, install/start an SSH server and authorize a dedicated dashboard SSH
public key for the intended user. On the dashboard host, install the OpenSSH client.
The private key must remain on the dashboard host, readable only by its owner.
Verify the worker's SSH host-key fingerprint independently before adding it to the
configured known_hosts file. Password prompts, automatic host-key acceptance and
SSH agent forwarding are not used.

The SSH user needs noninteractive sudo permission for the fixed commands used by
this executor: `snap list`, `snap list k8s`, `snap install k8s --classic
--channel=1.35-classic/stable`, `k8s join-cluster ... --name=... --address=...`, and
`k8s status --wait-ready --timeout 5m`. Configure/review sudoers on each intended
worker with `visudo`; do not grant unrestricted passwordless sudo. For a production
service, replace this prototype's CLI privilege access with a constrained broker.

Configure THIS app's `config.yaml` and restart it:

```yaml
remote_execution_enabled: true
ssh_targets:
  office-worker-01:
    host: 10.210.0.2
    user: ojas
    port: 22
    identity_file: /home/ojas/.ssh/inference-workers
    known_hosts_file: /home/ojas/.ssh/known_hosts
```

`10.210.0.2` is an example: replace it with the worker's actual WireGuard IP.
The configured address must be reachable by the dashboard AND control plane.
The SSH port must be allowed by the worker firewall/VPN rules.

In **Remote workers**, select a configured target and test SSH. Generate a worker
token in the existing setup wizard, enter that node name/token, review the target,
check the authorization box, then select **Execute worker join over SSH**.

Separate authenticated routes:

- `GET /api/v1/remote/targets`: configured target names/addresses and feature state.
- `POST /api/v1/remote/targets/{name}/check`: SSH/snap/sudo prerequisites.
- `POST /api/v1/remote/targets/{name}/join`: queue the explicit worker operation.
- `GET /api/v1/remote/jobs/{id}`: state and redacted step logs.

Only configured targets are accepted, with strict SSH host-key verification.
Node name/address must not already be registered in the current cluster. This
first executor supports **fresh workers without the k8s snap installed**; it refuses
existing installations so it cannot accidentally reconfigure another cluster.
It installs the configured snap channel, joins the worker, and checks readiness.
No arbitrary commands, remote bootstrap, reset, uninstall, hostname changes or
automatic VPN/NFS setup are exposed. No repository checkout is needed on the worker.

Jobs run in the dashboard process, one at a time per target. The UI polls status;
logs appear at step boundaries, not as a live byte stream. Tokens go to SSH stdin,
not the local ssh argument list, and are redacted from returned logs. They are not
stored in SQLite. Jobs/logs are kept in memory (last 50); restarting loses that
history. Closing the browser does not cancel a job. A timeout/disconnect/restart
does not guarantee that the remote command stopped: inspect the worker before
retrying. Failed operations are not rolled back. Once connected, refresh the node
overview to check the Kubernetes-reported state.

The local app remains a single-admin development prototype. Keep it loopback-only;
do not expose it through office ingress until the deployment/authentication design
has been completed. No actual remote machine was contacted during implementation.


## Invitation + device-code worker onboarding

This implements the flow described in the Gemini conversation, rather than copying
its unsigned email cookie and placeholder OAuth credentials. Authentication is
currently **invitation-bound local registration/login** with salted scrypt password
hashes and opaque, hashed server-side sessions. GitHub/Microsoft SSO is not wired;
those require real application registrations/provider settings and verified OAuth
callbacks. This is a device-authorization workflow, not an OAuth authorization
server claiming RFC 8628 compliance.

The browser dashboard does not execute local worker commands. The downloaded
`join.sh` runs on the worker and performs reviewed operations there only with
`--execute`. It does not send the private WireGuard key to the server.

### Set up the dedicated control-plane hub

Keep the current Tailscale service/address intact. In **Worker invitations**, select
**Show hub setup commands**, review them, then run them on the control-plane host.
They prepare a dedicated `pool0` interface, refuse to overwrite an existing config,
and enable IPv4 forwarding. They do not reset firewall rules or activate logical
network isolation. The existing `vpn/networks` records remain grouping metadata.

Set `wireguard.endpoint` to a **reachable UDP hostname:port**. The generated hub
listens on UDP 51820. An external port can be forwarded to that port, but this
application does not configure a router, Windows/WSL UDP forwarding, or corporate
firewalls. The HTTPS ngrok endpoint publishes the website, not WireGuard UDP.
Permit the required Kubernetes/Cilium traffic between approved nodes as well.
A public URL alone cannot establish VPN connectivity.

The worker AllowedIPs include `100.78.103.3/32` because the existing cluster advertises
that control-plane Tailscale address. New WG-only workers must route that exact
address through the WG hub. Keep Tailscale up on the control-plane host so Linux
continues to own it. Review this value against your actual advertised cluster
address. No existing cluster addresses or node configuration are migrated.

### Install the reviewed privilege brokers

The API remains an ordinary user process. Prepared helpers expose only node
inventory / worker-token issuance and selected peer operations on the dedicated
interface. They reject arbitrary commands, private-key reads, other interfaces,
and peer addresses outside the root-owned policy. No broad `sudo wg *`, `sudo k8s *`
or `NOPASSWD: ALL` rule is needed for this enrollment flow.

Review `privileged/wireguard.json` and `privileged/pool-dashboard.sudoers` first.
The supplied service user is `ojas`; adjust it if the dashboard runs as another user.
Then, on the control plane:

```bash
cd /home/ojas/hf/k8s-setup/vpn/dashboard-dev
sudo install -d -o root -g root -m 0755 /etc/pool-dashboard
sudo install -o root -g root -m 0644 privileged/wireguard.json /etc/pool-dashboard/wireguard.json
sudo install -o root -g root -m 0755 privileged/pool-wireguard /usr/local/sbin/pool-wireguard
sudo install -o root -g root -m 0755 privileged/pool-k8s /usr/local/sbin/pool-k8s
sudo visudo -cf privileged/pool-dashboard.sudoers
sudo install -o root -g root -m 0440 privileged/pool-dashboard.sudoers /etc/sudoers.d/pool-dashboard
```

Use the root-owned policy to restrict the helper even if dashboard settings are
changed. The provided policy owns only `pool0` and `10.210.0.0/16`. Hub config must
also be root-owned. Peer additions/removals are persisted with `wg-quick save pool0`;
this is why the interface must be dedicated to the dashboard.

Only after the hub, policy and UDP reachability are ready, set in THIS app config:

```yaml
enrollment_enabled: true
allow_token_generation: true
wireguard:
  interface: pool0
  endpoint: vpn.example.com:51820  # replace with the actual reachable endpoint
  server_address: 10.210.0.1
  allowed_ips: 10.210.0.0/16,100.78.103.3/32
  apply_peers: true
```

Restart the dashboard after changing configuration. All these mutations are disabled
in the checked-in config. The original `main.sh`, cluster scripts and
`k8s/nfs-shared.sh` are not changed by this update.

### Invite, authenticate, approve, join

1. Administrator selects **Worker invitations** and supplies the invited email,
   worker node name, network and expiry. The invitation is valid for one device;
   its hash alone is stored in SQLite. Copy the generated link/code/command to the
   intended worker through a trusted channel.
2. On the worker, install prerequisites (`wireguard-tools`, `wireguard`, `snapd`,
   `python3`, `iputils-ping`, and `curl`) first. Download and inspect `join.sh`, then run the generated
   command as the normal worker user. Add `--execute` only to authorize mutations.
3. The helper generates a local private key and submits only its public key with
   the invitation. It displays a verification URL and an 8-character device code.
4. Open the URL. Register using the invitation and its exact invited email if this
   is the first account; otherwise sign in. Review the device name, key and network,
   then authorize that device code. Account signup is invitation-backed, not proof
   of ownership of the email mailbox. Do not expose unrestricted public signup.
5. In the administrator dashboard, refresh devices, review the peer commands,
   check the authorization box and apply the peer. No worker sees the administrator
   bearer token or gets permission to call SSH/admin routes.
6. The worker receives a scoped, short-lived grant and its VPN configuration.
   Preview mode prints installation commands and waits for you to run them manually.
   `--execute` configures WireGuard locally, refusing existing `pool0.conf` or an
   already-installed k8s snap. It does not overwrite an existing node's setup.
7. After a recent authenticated WireGuard handshake is observed on the actual hub,
   the server issues the worker-specific Kubernetes join token. No token is issued
   merely because a browser/client claims to be connected. The helper then prints,
   or explicitly executes, the snap install/join/readiness commands.

Default invitation TTL is 60 minutes (configurable per invitation up to 24 hours).
Device requests/grants last at most 15 minutes. These exchange expiries do not automatically remove an already approved VPN peer; use explicit revocation for that. Grant/invitation/session secrets
are hashed in SQLite; passwords use independent random salts. Kubernetes join
credentials are not stored in the server database. The worker's protected local
state under `~/.local/state/pool-worker` supports resuming an unexpired device
request and stores a reviewed cluster plan in preview mode. Remove sensitive
plans after use. Tokens are sensitive even when displayed in copyable commands.

Join-token issuance is reserved atomically and not retried automatically after an
ambiguous failure. If its response is lost, or setup fails after snap installation,
an administrator must inspect the worker and arrange recovery. Restarting the
script is not an automatic reset/rejoin operation.

Revocation removes the managed WG peer and invalidates the invitation/grant. It
**does not** remove a Kubernetes node or revoke a Kubernetes credential already
issued; handle those separately with the existing cluster manager. Network
membership labels do not implement tenant isolation or per-pod network policy.

### Nginx / ngrok route

`/home/ojas/.config/ngrok/ngrok-router` now contains a prepared `/pool/` proxy route to
`127.0.0.1:8090`, preserving the prefix. The existing `ngrok.yml` already routes the
HTTPS endpoint to nginx on port 80, so it does not need a second endpoint. No tunnel
was started and `/etc/nginx` was not modified/reloaded during implementation.

The dashboard's `base_path: /pool` and relative asset/API URLs support this route.
Its default local preview URL is now `http://127.0.0.1:8090/pool/`. Worker browser
login is restricted to the origin in `public_url`; for a local-only test change
that setting to `http://127.0.0.1:8090/pool` before restarting. HTTPS cookies are used
when the public URL is HTTPS. Session cookies are opaque, HttpOnly and SameSite
Strict; cookie-authenticated changes also validate the browser Origin.

After reviewing the route, install it yourself when ready to expose the portal:

```bash
sudo install -m 0644 /home/ojas/.config/ngrok/ngrok-router /etc/nginx/sites-available/ngrok-router
sudo nginx -t
sudo systemctl reload nginx
```

Then start your already-configured ngrok endpoint. Public portal URL:
`https://flounder-sphere-dab.ngrok-free.dev/pool/`. The app and nginx must already be
running; starting ngrok does not start them. Worker pages are under `/pool/join/`
and `/pool/device/`. Do not share the local administrator token with workers.

### Shared storage tab

**Shared storage** generates separate commands for read-only NFS exports, client
`nfs-common` installation/mount/check/unmount, and rsync over SSH with a dry run
before the real copy. It also returns the Kubernetes NFS volume fragment. It never
reads a browser-entered filesystem path or executes a storage command on the server.
Run each command on the device indicated by the plan. The rsync destination is an
SSH path; it needs remote rsync, authentication and directory write permissions.

The original `k8s/nfs-shared.sh` is a reference only and is left untouched. NFS export
files generated here are dedicated `pool-<share>.exports` files; review/preserve
previous client entries before replacing them. No fstab changes, public NFS tunnel,
global firewall reset, or automatic recursive permission changes are made.

## Validation of this update

Tests mock all host/SSH/WireGuard operations. They cover invitation binding, account
identity and CSRF checks, authentication-before-approval, actual-handshake gating,
one-shot token issuance, secret storage, revocation, privilege broker restrictions,
base-path routes and storage command validation. No real VPN, worker, Kubernetes
membership, mount, rsync transfer or tunnel is changed by the test suite. Browser
rendering and real machine end-to-end enrollment still need manual verification.


## Worker disconnect and uninstall

The Gemini chat's device authorization / worker setup / disconnect flow is implemented
using the versioned FastAPI enrollment routes, rather than its example unsigned
identity cookie and unconditional deletion of `wg0.conf`.

- `GET /join.sh`: download the worker onboarding script.
- `POST /api/v1/enroll/device`, `/token`: start device authorization and poll.
- `POST /api/v1/enroll/authorize`: authenticated user consent.
- `GET /api/v1/enroll/vpn-config`: approved worker's public VPN settings.
- `POST /api/v1/enroll/cluster-config`: one-time join instructions after a verified handshake.
- `GET /uninstall.sh`: download the standalone worker cleanup script.
- `POST /api/v1/enrollment/uninstall-plan`: administrator-only commands for an enrolled node.

These paths are beneath `/pool` with the supplied config. Worker invitations now
include a **Worker uninstall commands** button. The plan does not execute removal.
On the control plane, remove the worker with `sudo k8s remove-node WORKER_NAME`
and verify the node list before removing its local snap. Keep its VPN connected
until cluster removal succeeds. Review/migrate workloads and local data first.

Run downloaded scripts as the same ordinary user used for onboarding; they invoke
sudo for individual host operations. New `join.sh --execute` runs record each
successful installation stage in `~/.local/state/pool-worker/installation.json`.
Preview/manual installations and older installations have no ownership record;
the cleanup script refuses automatic removal in that case.

```bash
bash uninstall.sh                         # Preview disconnect only
bash uninstall.sh --scope vpn             # Preview removal of pool0 configuration
bash uninstall.sh --scope cluster         # Preview k8s snap removal
bash uninstall.sh --scope all             # Preview both
# After administrator removal from the cluster, on the worker:
bash uninstall.sh --scope all --execute --node-removed --confirm-node WORKER_NAME
```

Execution checks the recorded node name, refuses detected control-plane
configuration, and verifies the installed WireGuard key before touching `pool0`.
`--node-removed` is the operator's confirmation, not a server attestation.
Kubernetes removal uses `snap remove k8s` without `--purge`. Disconnect preserves
the configuration; full VPN removal deletes only the dedicated configuration.
The administrator must also revoke the invitation / server-side peer. Shared VPN
packages, Tailscale, other WireGuard interfaces, model caches and NFS shares remain.
Local private keys and transient credentials are removed when both recorded
components have been uninstalled. Downloaded scripts remain available for inspection;
remove them yourself after use.


## Hostname-bound join tokens

`allow_token_generation` is enabled in the supplied dashboard config. The admin
join-token button calls `sudo -n /usr/local/sbin/pool-k8s get-join-token HOSTNAME --worker`,
whose root-owned helper executes `/snap/bin/k8s get-join-token HOSTNAME --worker`.
Install the reviewed helper/sudo policy as documented above if not already installed,
and restart the dashboard to load the config change.

Use the output of `hostname` on the worker as the invitation's node name. The
worker script sends its actual hostname during device enrollment and rejects a
mismatched invitation before applying VPN configuration. A mismatch leaves a fresh
invitation unclaimed. Older API clients may omit hostname; the current worker
script always provides it. The admin endpoint remains `POST /api/v1/cluster/join-token`
with JSON `{"node_name":"WORKER_HOSTNAME"}`. The enrollment endpoint issues the token
only after user authorization, administrator peer approval and a verified handshake.
WireGuard enrollment/apply flags remain independent of token generation.


## Navigation and NFS client selection

The sidebar contains Cluster overview, Setup wizard, main.sh walkthrough, Shared
storage and VPN workbench. Setup wizard has subtabs for Node configuration,
Worker invitations, SSH execution and Setup modules. The header's Invite worker
button and overview shortcut open the invitation subtab. A worker command plan can
transfer its node name/token to SSH execution for target review; execution still
requires an approved SSH target and explicit authorization.

Shared storage loads client choices from approved/connected WireGuard peers and
Kubernetes InternalIP addresses within the configured WireGuard pool or Tailscale
address range. It deduplicates addresses and excludes other LAN/public addresses.
Select individual nodes or Select all listed for a fixed export list. All addresses
in this VPN pool instead exports read-only to the configured WireGuard CIDR,
including future peers; it does not implicitly include Tailscale addresses outside
that pool. Select those explicitly if needed. Refresh nodes before generating a
new export. Cluster inventory failures leave recorded WireGuard choices available.
The authenticated `GET /api/v1/storage/clients` endpoint supplies these choices;
`POST /api/v1/storage/plan` accepts `access: selected` or `access: all-vpn`.


Navigation update: **＋ Node setup wizard** is again a standalone sidebar entry.
The final **⌘ Setup wizard** entry groups **Commands only**, **SSH execution** and
**Setup modules** as subtabs. **Worker invitations** lives beneath Control-plane
workspace in the sidebar, with header and overview shortcuts opening that page.


## Users, machines and cluster selection

User accounts are distinct from machines. One email can own a cluster, view another
invited cluster, and enroll several separate worker machines. A browser login never
joins/reassigns the browser's host machine. The new **User / machine login** link
opens `/pool/account/`, which uses the existing hashed-password/session system.
The worker device portal also links to this account dashboard.

To create your personal owner account, unlock the administrator console, open
**Worker invitations → User access / cluster ownership**, select the local cluster,
enter your own email and choose **Cluster owner**. Open the generated link, register
(or sign in using your existing account), then accept the invitation. Owners may
share their cluster overview using viewer invitations. To access another cluster,
accept its account invitation with the same login. Existing accounts do not need
another registration. Worker invitations remain separate, per-machine invitations;
approved workers receive dashboard membership without becoming administrators.

The header cluster selector switches administrator inventory. The user dashboard
selector includes only clusters with that user's membership; direct API requests
for other clusters are rejected. Remote selections display overview only. Local
setup, token generation, SSH, VPN and storage tools remain explicitly attached to
this host; switching cluster clears the prepared token plan. Worker invitation
commands always target this control plane, with a visible target-cluster field.
Access invitations have their own cluster and access-role dropdowns.

`cluster_id` is a stable directory identifier, not a Kubernetes-generated UID.
Configure `cluster_name` and reviewed `cluster_connections` in this folder's YAML
and restart the dashboard. A connection needs a pinned, read-only inventory command
prefix (see the commented SSH example in config.yaml). The remote broker must
already be installed and reachable; no SSH keys or remote passwords are created by
this update. This does not merge Kubernetes clusters or their WireGuard networks.
The local cluster is available immediately; no sample remote clusters are inserted.

Account dashboard routes are beneath `/api/v1/enroll/workspace`: `GET /me`,
`GET /clusters/{id}/nodes`, `POST /register`, `/accept` and `/invitations`.
Administrator directory routes are beneath `/api/v1/workspaces`: `GET /clusters`,
`GET /clusters/{id}/nodes`, `POST /invitations` and `/revoke-membership`.
Account-viewer/owner cookies do not authorize the host-admin APIs. Account ownership
here grants overview sharing, not arbitrary host execution or Kubernetes admin.
Invitations are email-bound, expire after 24 hours, and are accepted once. Removing
a dashboard membership does not revoke Kubernetes credentials or a VPN peer.

### Current machine role restriction

The current join.sh sends SHA-256 of a namespaced `/etc/machine-id`; the raw OS ID
and private WireGuard key are not transmitted. The host registers as control plane.
Worker enrollment atomically reserves a distinct machine fingerprint in the local
workspace registry. A fingerprint already assigned to any cluster/role is rejected;
only a separate machine can receive another role. The script also refuses machines
with an existing k8s snap before contacting enrollment, including preview mode.
Deleting VPN credentials does not release the machine assignment automatically.
Pending/failed reservations require administrator review; role switching is not
implemented. Older scripts must be downloaded again because fingerprint is required.
Older enrolled workers lack this fingerprint and cannot be retroactively identified
from hostname alone.

This is coordination within this dashboard's registry, not hardware attestation or
a distributed global lock. Independent dashboard installations do not yet share
machine/account databases. Their owners must use a shared identity/registry service
before enforcing the restriction across independent deployments. The local script
check prevents normal accidental reuse, but a modified client can lie about its
fingerprint. Cross-cluster inventory and invitations in this console do not claim
to implement that future shared identity service or multi-cluster provisioning.

For local browser authentication, set this app's `public_url` to the URL you use
(e.g. `http://127.0.0.1:8090/pool`) and restart; public HTTPS deployments should retain
their actual HTTPS URL. Cookie-origin checks intentionally reject another origin.
