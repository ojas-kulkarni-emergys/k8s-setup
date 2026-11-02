cd /home/ojas/hf/k8s-setup

set -a
source k8s/node/litellm/.env
set +a

sudo k8s kubectl create secret generic litellm-secrets \
  -n "$LITELLM_NAMESPACE" \
  --from-literal="LITELLM_MASTER_KEY=$LITELLM_MASTER_KEY" \
  --dry-run=client -o yaml | sudo k8s kubectl apply -f -

envsubst < k8s/node/litellm/config.yaml |
  sudo k8s kubectl create configmap litellm-config \
    -n "$LITELLM_NAMESPACE" \
    --from-file=config.yaml=/dev/stdin \
    --dry-run=client -o yaml |
  sudo k8s kubectl apply -f -