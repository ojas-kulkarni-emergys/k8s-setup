# Pool Console — isolated development prototype

Local dashboard for an office-wide Canonical Kubernetes inference pool. Kept under
`vpn/dashboard-dev` because the VPN control plane is experimental. Existing main.sh,
cluster scripts, VPN installers, config.yaml and active ingress are not modified.

The current priority deployment is reverse-kt; see its `deploy/canonical/README.md`.
Nothing in this dashboard builds images, deploys reverse-kt, or rewrites WireGuard.

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
  join/bootstrap on the dashboard host. No SSH/remote worker agent is installed.
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

Tests call the ASGI app with mocked host commands; short sync handlers run inline
in the test harness to avoid test-client portal/thread dependence. No real cluster
commands, secrets, VPN state or firewall rules are modified. Browser rendering is
not verified by the API tests. This folder is not yet a production control plane.
