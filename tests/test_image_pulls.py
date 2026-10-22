"""Offline tests execute the Bash modules against mocked host commands."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest
import yaml

ROOT = Path(__file__).resolve().parents[1]

class ModuleTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        shutil.copytree(ROOT / 'k8s', self.root / 'k8s')
        shutil.copy(ROOT / 'main.sh', self.root / 'main.sh')
        # Isolated test copies bypass only root guards; production keeps them.
        for path in (self.root / 'k8s').rglob('*.sh'):
            text=path.read_text().replace('[[ $EUID -eq 0 ]]', '[[ 0 -eq 0 ]]').replace('[[ $EUID -ne 0 ]]', '[[ 0 -ne 0 ]]')
            path.write_text(text)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.log = self.root / 'commands'
        self.config = yaml.safe_load((ROOT / 'config.yaml').read_text())
        self.config['vpn'] = 'none'
        self.config['kubernetes']['node_address'] = '192.0.2.1'
        self.config['kubernetes']['addons'] = []
        image_script=self.root/'k8s/services/pull-cluster-images.sh'
        image_script.write_text(image_script.read_text().replace('/snap/k8s/current/bin/ctr',str(self.bin/'ctr')))
        self.save()
        self.env={**os.environ, 'PATH':str(self.bin)+':'+os.environ['PATH'], 'TEST_LOG':str(self.log)}
        self.mock('timeout', 'printf "%s\\n" "$*" >> "$TEST_LOG"\nshift 2\nexec "$@"')
        self.mock('ctr', 'if [[ " $* " == *" --local "* ]]; then exit 0; else exit 124; fi')
        self.mock('k8s', '''printf 'k8s %s\\n' "$*" >> "$TEST_LOG"
if [[ "$1 $2" == 'kubectl get' && "$3" == pods ]]; then
 echo '{"items":[{"spec":{"containers":[{"image":"extra:v1"},{"image":"ghcr.io/canonical/cilium:1.18.4-ck0"}]}}]}'
elif [[ "$1" == config ]]; then echo 'apiVersion: v1'; fi''')
        for command in ('helm','snap','hostnamectl'):
            self.mock(command, f'printf "{command} %s\\n" "$*" >> "$TEST_LOG"')

    def mock(self, name, body):
        path=self.bin/name
        path.write_text('#!/bin/bash\n'+body+'\n')
        path.chmod(0o755)

    def save(self):
        (self.root/'config.yaml').write_text(yaml.safe_dump(self.config))

    def run_module(self, name, *args, input=''):
        return subprocess.run(['bash',str(self.root/name),*map(str,args)],env=self.env,
                              cwd='/tmp',input=input,text=True,capture_output=True)

    def test_image_fallback_and_discovery(self):
        result=self.run_module('k8s/services/pull-cluster-images.sh')
        self.assertEqual(result.returncode,0,result.stderr)
        calls=self.log.read_text()
        self.assertEqual(calls.count('--kill-after=30s 5m'),7)
        self.assertEqual(calls.count('--kill-after=30s 20m'),7)
        self.assertEqual(calls.count('images pull --local'),7)

    def test_failed_download_returns_failure(self):
        self.mock('ctr','exit 124')
        result=self.run_module('k8s/services/pull-cluster-images.sh','--local-only')
        self.assertEqual(result.returncode,1)
        self.assertIn('Images still unavailable',result.stderr)

    def test_headlamp_direct_install_and_dispatch(self):
        result=self.run_module('k8s/services/headlamp.sh','install')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('helm --kubeconfig',self.log.read_text())
        self.assertIn('upgrade --install headlamp headlamp/headlamp',self.log.read_text())
        result=self.run_module('main.sh','--headlamp',input='0\n')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertNotIn('Worker node name',result.stdout)

    def test_control_and_worker_role_validation(self):
        result=self.run_module('k8s/cluster/setup-control-plane.sh')
        self.assertEqual(result.returncode,0,result.stderr)
        result=self.run_module('k8s/cluster/setup-worker.sh')
        self.assertNotEqual(result.returncode,0)
        self.config['role']='worker'
        self.config['kubernetes']['join_token']='test-token'
        self.save()
        result=self.run_module('k8s/cluster/setup-worker.sh')
        self.assertEqual(result.returncode,0,result.stderr)
        result=self.run_module('k8s/cluster/setup-control-plane.sh')
        self.assertNotEqual(result.returncode,0)
        self.assertIn('Config role must be control',result.stderr)

    def test_vpn_address_and_cancel_uninstall(self):
        result=self.run_module('k8s/cluster/vpn_manager.sh','address')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertEqual(result.stdout.strip(),'192.0.2.1')
        result=self.run_module('k8s/cluster/vpn_manager.sh','uninstall',input='no\n')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('Cancelled',result.stdout)
        self.assertFalse(self.log.exists())

    def test_menu_and_removed_service_layer(self):
        result=self.run_module('main.sh',input='0\n')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('6) Services',result.stdout)
        self.assertFalse((ROOT/'k8s/lib').exists())

    def test_registry_apply_uses_node_manifest(self):
        result=self.run_module('k8s/services/docker-registry.sh','apply')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('kubectl apply -f '+str(self.root/'k8s/node/docker-registry.yaml'),self.log.read_text())

    def test_node_manager_dispatches_both_roles(self):
        result=self.run_module('main.sh','--install-cluster')
        self.assertEqual(result.returncode,0,result.stderr)
        self.config['role']='worker'
        self.config['kubernetes']['join_token']='test-token'
        self.save()
        result=self.run_module('main.sh','--install-cluster')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertFalse((ROOT/'k8s/cluster/setup-cluster.sh').exists())
        self.assertFalse((ROOT/'k8s/cluster/cluster-common.sh').exists())

    def test_models_and_services_independent_menus(self):
        result=self.run_module('main.sh','--models',input='5\n')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('llm-d Setup Menu',result.stdout)
        result=self.run_module('main.sh','--services',input='0\n')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('Docker registry (install / manage',result.stdout)

    def test_custom_monitoring_manifest_keeps_declared_namespace(self):
        self.mock('sudo', 'exec "$@"')
        kubeconfig=self.root/'kubeconfig'
        kubeconfig.write_text('apiVersion: v1\n')
        self.config['llm_d']['kubeconfig']=str(kubeconfig)
        self.save()
        result=self.run_module('main.sh','--models',input='1\n1\n1\ny\n5\n')
        self.assertEqual(result.returncode,0,result.stderr)
        command='k8s kubectl apply -f '+str(self.root/self.config['llm_d']['manifests_dir']/'llm-monitoring.yaml')
        self.assertIn(command+'\n',self.log.read_text())
        self.assertNotIn(command+' -n',self.log.read_text())

    def test_config_manifest_paths_and_retired_entry_points(self):
        config=yaml.safe_load((ROOT/'config.yaml').read_text())['llm_d']
        for key in ('manifests_dir','manifest_path','model_template_path','distilgpt2_manifest_path','generated_deployments_dir'):
            self.assertTrue((ROOT/config[key]).exists(),key)
            self.assertTrue((ROOT/config[key]).is_relative_to(ROOT/config['manifests_dir']),key)
        self.assertNotEqual(config['manifest_path'],config['generated_manifest_path'])
        self.assertFalse((ROOT/'install.sh').exists())
        self.assertFalse((ROOT/'k8s/node/llm-d-router.wizard.sh').exists())

    def test_release_namespace_and_router_references(self):
        llm=self.config['llm_d']
        self.assertEqual(llm['namespace'],'llm-d-deployments')
        self.assertEqual(llm['release_name'],'llm-router')
        self.assertNotIn('guide_name',llm)
        for path in (ROOT/llm['manifests_dir']).rglob('*.yaml'):
            self.assertNotIn('quickstart',path.read_text())
            for doc in yaml.safe_load_all(path.read_text()):
                if isinstance(doc,dict) and doc.get('metadata',{}).get('namespace'):
                    self.assertIn(doc['metadata']['namespace'],(llm['namespace'],'__NAMESPACE__'))
        router=(ROOT/llm['manifest_path']).read_text()
        self.assertIn('llm-router-epp-model-servers.llm-d-deployments.svc.cluster.local',router)
        self.assertIn('inference.networking.k8s.io/pool: "llm-router"',router)

    def test_registry_existing_install_opens_manager_without_apply(self):
        result=self.run_module('main.sh','--registry',input='2\n0\n0\n')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('already installed',result.stdout)
        self.assertIn('Registry contents',result.stdout)
        self.assertNotIn('kubectl apply',self.log.read_text())

    def test_registry_delete_requires_confirmation_and_accepts_oci(self):
        self.mock('curl', 'printf "curl %s\n" "$*" >> "$TEST_LOG"; printf "Docker-Content-Digest: sha256:%064d\\r\\n" 0')
        result=self.run_module('k8s/node/registry_manager.sh','delete','example','v1',input='no\n')
        self.assertEqual(result.returncode,0,result.stderr)
        calls=self.log.read_text()
        self.assertIn('application/vnd.oci.image.index.v1+json',calls)
        self.assertNotIn('-X DELETE',calls)

    def test_headlamp_token_adds_only_node_read_permissions(self):
        result=self.run_module('k8s/services/headlamp.sh','token')
        self.assertEqual(result.returncode,0,result.stderr)
        calls=self.log.read_text()
        self.assertIn('create clusterrole headlamp-node-reader --verb=get,list,watch --resource=nodes',calls)
        self.assertIn('--serviceaccount=kube-system:headlamp-viewer --clusterrole=headlamp-node-reader',calls)
        self.assertNotIn('cluster-admin',calls)

    def test_config_only_ingress_and_tailscale_are_separate(self):
        directory=ROOT/'k8s/ingress'
        self.assertFalse(list(directory.glob('*.sh')))
        docs=list(yaml.safe_load_all((directory/'ingress.yaml').read_text()))
        self.assertEqual(len(docs),5)
        hosts=set()
        for doc in docs:
            self.assertEqual(doc['kind'],'Ingress')
            self.assertEqual(doc['spec']['ingressClassName'],'cilium')
            self.assertEqual(doc['metadata']['annotations']['ingress.cilium.io/loadbalancer-mode'],'shared')
            self.assertNotIn('config',doc['spec'])
            host=doc['spec']['rules'][0].get('host','*')
            self.assertNotIn(host,hosts)
            hosts.add(host)
            self.assertGreater(doc['spec']['rules'][0]['http']['paths'][0]['backend']['service']['port']['number'],0)
        values=yaml.safe_load((directory/'tailscale.values.yaml').read_text())
        self.assertEqual(values['oauth']['clientSecret'],'')
        self.assertEqual(values['ingressClass']['name'],'tailscale')
        self.assertNotIn('tailscale_operator',self.config)
        self.assertNotIn('tailscale_ingress',self.config)

    def test_headlamp_base_path_is_in_helm_values_not_ingress(self):
        docs=list(yaml.safe_load_all((ROOT/'k8s/ingress/ingress.yaml').read_text()))
        headlamp=next(doc for doc in docs if doc['metadata']['name']=='headlamp')
        self.assertNotIn('config',headlamp['spec'])
        self.assertNotIn('host',headlamp['spec']['rules'][0])
        self.assertEqual(headlamp['spec']['rules'][0]['http']['paths'][0]['path'],'/headlamp')
        values=yaml.safe_load((ROOT/'k8s/ingress/headlamp.values.yaml').read_text())
        self.assertEqual(values['config']['baseURL'],'/headlamp')
        result=self.run_module('k8s/services/headlamp.sh','install')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('-f '+str(self.root/'k8s/ingress/headlamp.values.yaml'),self.log.read_text())

    def test_image_recovery_does_not_require_config_or_common(self):
        (self.root/'config.yaml').unlink()
        (self.root/'k8s/common.sh').unlink()
        result=self.run_module('k8s/services/pull-cluster-images.sh','--local-only')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertNotIn('cfg ',(ROOT/'k8s/services/pull-cluster-images.sh').read_text())
        self.assertNotIn('source ',(ROOT/'k8s/services/pull-cluster-images.sh').read_text())

    def test_image_recovery_direct_route_does_not_pass_config(self):
        result=self.run_module('main.sh','--pull-images')
        self.assertEqual(result.returncode,0,result.stderr)

    def test_image_recovery_discovery_unavailable_uses_builtin_list(self):
        self.mock('k8s','exit 1')
        result=self.run_module('k8s/services/pull-cluster-images.sh','--local-only')
        self.assertEqual(result.returncode,0,result.stderr)
        self.assertIn('built-in image list',result.stderr)
        self.assertEqual(self.log.read_text().count('images pull --local'),6)
