#!/usr/bin/env bash
# NFS shared model cache: run active sections 1 and 2 on the STORAGE SERVER only.
# Client tests and optional commands remain commented: run them on the named host.
# Storage server: RACIT026 / 100.78.103.3
# Worker: RACIT054 / 100.81.95.34
# No config.yaml dependency, shell variables, or functions.

# 1. STORAGE SERVER: install NFS and copy the existing model cache.
sudo apt-get update
sudo apt-get install -y nfs-kernel-server rsync
sudo mkdir -p /home/ojas/hf/k8s-setup/nfs/srv
# Copy hub/ with its blobs, refs, snapshots, and relative symlinks intact.
# This does not copy the HF login token from the parent cache directory.
sudo rsync -a /home/ojas/.cache/huggingface/hub /home/ojas/hf/k8s-setup/nfs/srv/model-cache/huggingface/
sudo chmod -R a+rX /home/ojas/hf/k8s-setup/nfs/srv/model-cache/huggingface

# 2. STORAGE SERVER: export read-only to the control plane and worker.
# This replaces only this dedicated export file. Preserve additional clients
# if you have already added them; add their exact addresses to the export line.
sudo install -d -m 0755 /etc/exports.d
sudo tee /etc/exports.d/srv.exports >/dev/null <<'EOF'
/home/ojas/hf/k8s-setup/nfs/srv 100.78.103.3(ro,sync,no_subtree_check,root_squash) 100.81.95.34(ro,sync,no_subtree_check,root_squash)
EOF
sudo exportfs -rav
sudo systemctl enable --now nfs-kernel-server
sudo exportfs -v
sudo systemctl status nfs-kernel-server --no-pager

# 3. STORAGE SERVER: only if UFW is already active, allow NFSv4 over Tailscale.
# Also allow these connections in your Tailscale policy if it restricts traffic.
# Do not expose NFS to the public internet. Do not enable/reset UFW here.
sudo ufw status
# sudo ufw allow in on tailscale0 from 100.81.95.34 to any port 2049 proto tcp

# 4. EVERY ELIGIBLE KUBERNETES NODE: install the NFS client.
# This includes the control plane if model pods may run there.
sudo apt-get update
sudo apt-get install -y nfs-common

# 5. WORKER: temporarily mount and check the share.
sudo mkdir -p /mnt/model-cache-test
sudo mount -t nfs -o ro,vers=4.1 100.78.103.3:/home/ojas/hf/k8s-setup/nfs/srv /mnt/model-cache-test
# ls /mnt/model-cache-test/hub
# findmnt /mnt/model-cache-test
# sudo umount /mnt/model-cache-test
# No permanent host mount or /etc/fstab entry is needed with a Kubernetes nfs volume.

# 5. Update the path
sudo systemctl stop nfs-kernel-server
sudo rm -f /etc/exports.d/srv.exports
sudo tee /etc/exports.d/srv.exports >/dev/null <<'EOF'
/home/ojas/hf/k8s-setup/nfs/srv 100.78.103.3(ro,sync,no_subtree_check,root_squash) 100.81.95.34(ro,sync,no_subtree_check,root_squash)
EOF
sudo exportfs -rav
sudo systemctl restart nfs-kernel-server
sudo exportfs -v
sudo systemctl status nfs-kernel-server --no-pager

# 6. STORAGE SERVER: refresh the shared cache after downloading more models locally.
# Rerunning rsync copies new/updated files without deleting destination files.
# Run after the model download finishes; avoid changing weights while pods load them.
# sudo rsync -a /home/ojas/.cache/huggingface/hub /srv/model-cache/huggingface/
# sudo chmod -R a+rX /srv/model-cache/huggingface

# 7. KUBERNETES CONFIGURATION: enable later, not executed by this reference.
# In /home/ojas/hf/k8s-setup/config.yaml under llm_d:
#   model_cache_storage: nfs
#   model_cache_nfs_server: 100.78.103.3
#   model_cache_nfs_path: /srv/model-cache/huggingface
# Generate a model manifest with the llm-d wizard and review it before applying.
# Existing deployment manifests retain commented NFS examples; changing config.yaml
# does not rewrite already-generated manifests or live Kubernetes resources.

# 8. DIAGNOSTICS: run the server commands on the storage server.
# sudo journalctl -u nfs-kernel-server -n 50 --no-pager
# sudo exportfs -v
# sudo ss -lnt 'sport = :2049'
# Run these on the worker to check the route and VPN connection.
# ip route get 100.78.103.3
# tailscale ping 100.78.103.3
# On WSL, the storage server kernel must support nfsd; inspect the service log
# if nfs-kernel-server cannot start. The storage machine must remain online.
