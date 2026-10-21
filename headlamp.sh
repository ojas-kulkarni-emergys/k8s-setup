sudo k8s kubectl top nodes
sudo k8s kubectl get pods -A | grep -i metrics-server
sudo k8s kubectl get apiservice | grep metrics

helm repo add headlamp https://kubernetes-sigs.github.io/headlamp/
helm repo update

helm upgrade --install headlamp headlamp/headlamp \
  --namespace kube-system --create-namespace

sudo k8s kubectl port-forward \
  -n kube-system service/headlamp 8080:80

sudo k8s kubectl create token headlamp --namespace kube-system