sudo k8s kubectl rollout restart daemonset/cilium \
  -n kube-system

# Restart Rawfile CSI controller StatefulSet
sudo k8s kubectl rollout restart statefulset/ck-storage-rawfile-csi-controller \
  -n kube-system

# Restart Rawfile CSI node DaemonSet
sudo k8s kubectl rollout restart daemonset/ck-storage-rawfile-csi-node \
  -n kube-system

# Restart CoreDNS
sudo k8s kubectl rollout restart deployment/coredns \
  -n kube-system

# Restart Headlamp
sudo k8s kubectl rollout restart deployment/headlamp \
  -n kube-system

# Restart Metrics Server
sudo k8s kubectl rollout restart deployment/metrics-server \
  -n kube-system

# Restart Grafana
sudo k8s kubectl rollout restart deployment/grafana \
  -n llm-d-deployments

# Restart docker-registry 
sudo k8s kubectl rollout restart deployment/docker-registry \
  -n docker-registry

sudo k8s kubectl rollout restart deployment/reverse-kt \
  -n inference-demo

tailscale status
ip -4 addr show dev tailscale0


sudo k8s kubectl port-forward -n docker-registry svc/registry 5000:5000
sudo k8s kubectl port-forward --address 127.0.0.1 \
  -n docker-registry svc/registry 80:5000
curl http://localhost:5000/v2/_catalog
curl -i https://flounder-sphere-dab.ngrok-free.dev/registry/v2/_catalog

cd /home/ojas/hf/reverse-kt

sudo nano /etc/docker/daemon.json
```
{
  "insecure-registries": ["100.78.103.3:30500"]
}
```

mkdir -p wheels

pip download -d wheels \
  --timeout 180 --retries 20 \
  --extra-index-url https://download.pytorch.org/whl/cpu \
  torch==2.14.1+cpu

pip download -d wheels \
  --timeout 180 --retries 20 \
  -r requirements-frozen.txt

pip download -d wheels \
  --timeout 180 --retries 20 \
  -r requirements-api.txt

pip download \
  -d wheels \
  --timeout 180 --retries 20 \
  -r requirements-ui.txt

docker build \
  -f Dockerfile \
  --target inference \
  -t 100.78.103.3:30500/reverse-kt-api:dev . && \
docker build \
  -f Dockerfile \
  --target ui \
  -t 100.78.103.3:30500/reverse-kt-ui:dev . && \
docker push 100.78.103.3:30500/reverse-kt-api:dev && \
docker push 100.78.103.3:30500/reverse-kt-ui:dev

curl --fail http://100.78.103.3:30500/v2/reverse-kt-api/tags/list

curl --fail http://100.78.103.3:30500/v2/reverse-kt-ui/tags/list