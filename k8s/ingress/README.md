# Standard ingress; optional Tailscale config kept separately

This directory contains configuration only:

- `ingress.yaml`: standard Kubernetes routes for Headlamp, LLM router, Grafana,
  Prometheus and Docker registry. This is the normal access method.
- `headlamp.values.yaml`: Helm base-path setting for `/headlamp`, loaded by the
  Headlamp installer. Do not pass it to kubectl apply.
- `tailscale.values.yaml`: optional Tailscale Operator Helm values. It is separate
  from standard ingress, contains no credentials, and exposes no apps by itself.

No Bash installation/menu scripts are maintained in this directory.

## What ingress does

An Ingress maps an HTTP hostname/path to a Kubernetes Service. A running ingress
controller receives the request and performs the routing. The YAML alone neither
installs the controller nor makes an IP reachable from the host.

```text
Host browser -> controller IP:80 -> Ingress rule -> Service -> application pod
```

The supplied routes use `ingressClassName: cilium` and Cilium's shared load balancer
mode, suitable for a cluster using its Cilium ingress controller. Verify the class
and the controller's external address rather than assuming the node or pod IP:

```bash
sudo k8s enable ingress
sudo k8s kubectl get ingressclass
sudo k8s kubectl get services -A -o wide
```

If your installed ingress controller uses another class, edit ingressClassName in
all five documents and remove the Cilium-specific shared-loadbalancer annotation.
Canonical's built-in ingress requires a working cluster network. Install the
backend applications and their namespaces first; the routes do not create apps.

Apply the config:

```bash
sudo k8s kubectl apply -f /home/ojas/hf/k8s-setup/k8s/ingress/ingress.yaml
sudo k8s kubectl get ingress -A -o wide
```

## Headlamp without a hostname or hosts-file change

The Headlamp Ingress has no `host` match and preserves `/headlamp`. The application
must also serve under that path: `config.baseURL` belongs in the Helm values file
`headlamp.values.yaml`, NOT under `Ingress.spec`. Update both with:

```bash
sudo bash /home/ojas/hf/k8s-setup/k8s/services/headlamp.sh install
sudo k8s kubectl apply -f /home/ojas/hf/k8s-setup/k8s/ingress/ingress.yaml
curl -i --max-time 10 http://100.78.103.3:31177/headlamp/
```

Use the current node IP/NodePort if these change. Your last Service listing had
HTTP NodePort 31177. `http://localhost:31177/headlamp/` works only if NodePort is
reachable via localhost in your host/WSL setup. No host header or hosts-file entry
is required for this Headlamp route. A normal port-forward to Headlamp itself now
uses `http://localhost:8080/headlamp/` because its base path has changed.

The other four routes still use their existing hostnames and `/` paths; they
need their own base-path setup before conversion. Your existing nginx / ngrok
routing is not changed by these files.

The earlier 503 is separate: the backend Service returned 200 directly while
Envoy timed out connecting upstream. These path fixes do not repair that dataplane
connectivity issue. Verify pod connectivity and ingress proxy logs if it persists.

## Access from the host machine

Find an ingress controller address the host can reach. For LoadBalancer mode this
is its EXTERNAL-IP. If pending, configure a suitable reachable load-balancer address
pool first; applying Ingress rules does not allocate a usable network by itself.
If your controller instead uses host networking, use its listening node address.
A NodePort controller needs its node address AND its assigned port.

For a local test, replace `INGRESS_IP` below with that real reachable address:

```bash
curl --resolve headlamp.k8s.test:80:INGRESS_IP http://headlamp.k8s.test/
```

Add the following entry to the hosts file on the machine running your browser,
replacing INGRESS_IP (the text is a template, not a literal IP):

```text
INGRESS_IP headlamp.k8s.test llm-router.k8s.test grafana.k8s.test prometheus.k8s.test registry.k8s.test
```

For a Linux host, edit `/etc/hosts`. For a Windows browser accessing WSL Kubernetes,
edit `C:\Windows\System32\drivers\etc\hosts` as Administrator. Editing WSL's
`/etc/hosts` alone does not configure Windows name resolution. WSL's NAT/mirrored
networking and Windows firewall must allow access to the controller. A WSL-local
load-balancer address is not automatically reachable from Windows or the LAN.
Do not map these names to 127.0.0.1 unless you verified the controller is listening
through localhost on that host.

For hostname-based routes, open e.g. `http://grafana.k8s.test`. Those names
can share the same controller IP/port; the Host header selects the app.
For Headlamp, use `/headlamp/` as described above.
Opening the raw IP does not match the supplied hostname rules. `.test` is a local
example suffix, not automatically registered DNS. Use your own DNS domain instead
when needed. No persistent kubectl port-forward is needed once routing works.

These examples use HTTP. For HTTPS, create a TLS Secret in each backend namespace
and add `spec.tls` for the corresponding host/secret. Standard ingress does not
provide automatic certificates here. Headlamp still needs its login token. Other
apps retain their authentication; use the intended trusted network and configure
TLS before sending credentials over an untrusted connection.

## What “Tailscale ingress” means

It is an Ingress handled by Tailscale Operator (`ingressClassName: tailscale`) rather
than your normal controller. The operator provisions tailnet proxies and private
`*.ts.net` HTTPS addresses. Those addresses require Tailscale-connected clients and
appropriate access policy. It is optional and not used by ingress.yaml.

Your existing host/node Tailscale VPN is independent: a normal ingress controller
can be reached through a node's Tailscale IP ONLY if it actually listens there and
routing/firewall/access policy permit it. Having Tailscale installed alone does not
create app routes or expose ClusterIP services.

## Optional Tailscale Operator config

`tailscale.values.yaml` is passed to Helm, not `kubectl apply`. It relies on an
existing `operator-oauth` Secret in namespace `tailscale`, containing `client_id`
and `client_secret`. Set up operator OAuth permissions/tags, MagicDNS and HTTPS in
the Tailscale console according to its official installation documentation. The
file does not store your credentials or enable public Funnel.

```bash
helm repo add tailscale https://pkgs.tailscale.com/helmcharts
helm repo update tailscale
helm upgrade --install tailscale-operator tailscale/tailscale-operator \
  --namespace tailscale --create-namespace \
  -f /home/ojas/hf/k8s-setup/k8s/ingress/tailscale.values.yaml
```

Helm must use a kubeconfig pointing to your Canonical cluster (the user running
Helm needs access). A previously installed operator or its old Tailscale ingresses
is not uninstalled merely by removing scripts. Inspect existing ingresses before
switching; remove only the old resources you intend to retire.

References:
- https://kubernetes.io/docs/concepts/services-networking/ingress/
- https://documentation.ubuntu.com/canonical-kubernetes/latest/snap/howto/networking/default-ingress/
- https://docs.cilium.io/en/stable/network/servicemesh/ingress/
- https://tailscale.com/docs/kubernetes-operator/install-operator
