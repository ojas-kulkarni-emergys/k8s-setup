# Pool Console — isolated development prototype

Local dashboard for an office-wide Canonical Kubernetes inference pool. Kept under
`vpn/dashboard-dev` because the VPN control plane is experimental. Existing main.sh,
cluster scripts, VPN installers, config.yaml and active ingress are not modified.

The current priority deployment is reverse-kt; see its `deploy/canonical/README.md`.
Nothing in this dashboard builds images, deploys reverse-kt, or rewrites WireGuard.
Optional SSH worker execution is now available, disabled by default; see below.

## Commands-only source walkthrough

Open **Commands only** in the dashboard. Its route dropdown is read from the
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
http://127.0.0.1:8090. Read `.state/access-token` locally and enter it in the UI.
State/access token files are ignored by Git; don't publish them. The browser holds
the access token in memory, not cookies/localStorage. APIs require a Bearer token;
no wildcard CORS or unauthenticated cluster-mutation endpoints are enabled.

This is a host-side app, not a pod with a privileged socket/host mount. Configure
`command_prefix` in THIS folder's config for access to Canonical `k8s`. By default
it uses `sudo -n k8s`; if that user lacks noninteractive permission, inventory returns
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
  Includes a default company-wide record. THIS IS METADATA ONLY. No WireGuard peers,
  routing, IP forwarding or iptables changes are applied and no isolation is claimed.

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
