'use strict';
let accessToken = '', plan = null;
let workspaceClusters=[],localCluster='',selectedCluster='';
const $ = id => document.getElementById(id);
const titles = {overview:'Cluster overview', wizard:'Node setup wizard', tooling:'Setup wizard', vpn:'VPN workbench', modules:'Setup modules', remote:'Remote workers', commands:'Commands only', onboarding:'Worker invitations', storage:'Shared storage'};
const message = text => { $('message').textContent = text || ''; };
async function api(path, method='GET', body) {
  const response = await fetch(new URL('api/v1' + path, document.baseURI), {method, cache:'no-store', headers: {
    'Authorization':'Bearer ' + accessToken, 'Content-Type':'application/json'
  }, ...(body ? {body:JSON.stringify(body)} : {})});
  const data = await response.json();
  if (!response.ok) throw new Error(typeof data.detail === 'string' ? data.detail : 'Check the form fields and try again.');
  return data;
}
function cell(row, text) { const element = document.createElement('td'); element.textContent = text; row.append(element); }
async function refreshNodes() {
  try {
    const cluster=selectedCluster;
    const {nodes} = await api('/workspaces/clusters/'+encodeURIComponent(cluster)+'/nodes');
    if(cluster!==selectedCluster)return;
    $('total').textContent = nodes.length;
    $('workers').textContent = nodes.filter(n => n.ready && n.roles.includes('worker')).length;
    $('gpus').textContent = nodes.reduce((sum,n) => sum + (Number(n.gpu)||0),0);
    $('nodes').replaceChildren();
    for (const n of nodes) {
      const row = document.createElement('tr');
      [n.name,n.roles.join(', ')||'unlabelled',n.ready?'● Ready':'○ Not ready',
       n.addresses.find(a=>a.type==='InternalIP')?.address||'—',`${n.cpu||'—'} / ${n.memory||'—'}`,n.gpu].forEach(v=>cell(row,v));
      $('nodes').append(row);
    }
    if (!nodes.length) { const row=document.createElement('tr'); cell(row,'No nodes reported by the cluster.'); $('nodes').append(row); }
    message('Cluster inventory refreshed.');
  } catch(e) { message(e.message); }
}
async function refreshNetworks() {
  try {
    const data = await api('/vpn/networks');
    $('networks').replaceChildren(); $('member-network').replaceChildren();
    for (const n of data.networks) {
      const article=document.createElement('article'), title=document.createElement('h3'), cidr=document.createElement('code'), people=document.createElement('p'), state=document.createElement('small');
      title.textContent=n.name; cidr.textContent=n.subnet; people.textContent=n.members.join(', ')||'No members recorded'; state.textContent=n.state;
      article.append(title,cidr,people,state); $('networks').append(article);
      const option=document.createElement('option'); option.value=n.name; option.textContent=n.name; $('member-network').append(option);
    }
  } catch(e) { message(e.message); }
}
async function refreshModules() {
  try {
    const data=await api('/setup/modules'); $('module-list').replaceChildren();
    for(const m of data.modules) {const div=document.createElement('div'), path=document.createElement('span'), state=document.createElement('span'); path.textContent=m.path; state.textContent=m.available?'Available':'Not found'; div.append(path,state); $('module-list').append(div);}
  } catch(e) {message(e.message);}
}
let setupTab='commands';
function setupPanel(name, focus=false) {
  setupTab=name;
  document.querySelectorAll('[role=tabpanel]').forEach(panel=>panel.hidden=panel.id!=='setup-'+name);
  document.querySelectorAll('[role=tab]').forEach(button=>{
    const selected=button.dataset.setup===name;
    button.setAttribute('aria-selected',String(selected));button.tabIndex=selected?0:-1;
    if(selected && focus)button.focus();
  });
  if(accessToken && name==='commands')refreshCommandRoutes();
  if(accessToken && name==='remote')refreshRemote();
  if(accessToken && name==='modules')refreshModules();
}
function view(name) {
  if(selectedCluster && selectedCluster!==localCluster && !['overview','onboarding'].includes(name)){
    message('This workspace manages node setup, SSH, VPN and storage on the local cluster. Select the local cluster or open that cluster’s dashboard.');return;
  }
  if(name==='onboarding' && selectedCluster!==localCluster && selectedCluster){
    selectedCluster=localCluster;$('workspace-cluster').value=localCluster;
    updateClusterContext();
  }
  document.querySelectorAll('.view').forEach(v=>v.hidden=v.id!==name);
  document.querySelectorAll('aside [data-view]').forEach(b=>b.classList.toggle('active',b.dataset.view===name));
  $('page-title').textContent=titles[name]; message('');
  document.querySelectorAll('header [data-view="onboarding"]').forEach(button=>button.hidden=name==='onboarding');
  if(name==='tooling')setupPanel(setupTab);
  if(accessToken && name==='onboarding')refreshEnrollment();
  if(accessToken && name==='commands') refreshCommandRoutes();
  if(accessToken && name==='vpn') refreshNetworks();
  if(accessToken && name==='storage') refreshStorageClients();
}
document.querySelectorAll('[data-view]').forEach(b=>b.addEventListener('click',()=>view(b.dataset.view)));
document.querySelectorAll('[data-setup]').forEach(b=>b.addEventListener('click',()=>{
  setupTab=b.dataset.setup;view('tooling');
}));
document.querySelectorAll('[role=tab]').forEach(button=>button.addEventListener('keydown',event=>{
  const tabs=[...document.querySelectorAll('[role=tab]')];let index=tabs.indexOf(button);
  if(event.key==='ArrowRight')index=(index+1)%tabs.length;
  else if(event.key==='ArrowLeft')index=(index+tabs.length-1)%tabs.length;
  else if(event.key==='Home')index=0;
  else if(event.key==='End')index=tabs.length-1;
  else return;
  event.preventDefault();setupPanel(tabs[index].dataset.setup,true);
}));
$('access-form').addEventListener('submit',async e=>{e.preventDefault(); accessToken=$('access-token').value; $('access-token').value='';
  try {await api('/setup/modules'); await refreshWorkspaceClusters(); $('access').hidden=true; await refreshNodes(); const current=document.querySelector('.view:not([hidden])')?.id;if(current==='tooling')setupPanel(setupTab);if(current==='onboarding')refreshEnrollment();if(current==='storage')refreshStorageClients();if(current==='commands')refreshCommandRoutes();if(current==='vpn')refreshNetworks();} catch(error){accessToken='';message(error.message);}
});
$('refresh').onclick=refreshNodes;
$('refresh-networks').onclick=refreshNetworks;
document.querySelectorAll('input[name=mode]').forEach(input=>input.addEventListener('change',()=>{$('join-fields').hidden=input.value==='create' && input.checked; clearPlan();}));
$('generate-token').onclick=async()=>{
  try {const data=await api('/cluster/join-token','POST',{node_name:$('node-name').value}); $('join-token').value=data.token; message('Worker token generated. Prepare the worker plan, then clear it when finished.');}catch(e){message(e.message);}
};
$('node-form').addEventListener('submit',async e=>{
  e.preventDefault(); const mode=document.querySelector('input[name=mode]:checked').value;
  const body={node_name:$('node-name').value,address:$('node-address').value}; if(mode==='join')body.token=$('join-token').value;
  try {plan=await api('/setup/'+mode,'POST',body); $('plan').hidden=false; $('plan-note').textContent=`Run on: ${plan.execute_on}. ${plan.note}`; $('plan-commands').textContent=plan.commands.join('\n'); $('module-command').textContent=plan.module_command; $('download-plan').textContent=mode==='join'?'Download worker script':'Download control-plane script';$('plan-ssh').hidden=mode!=='join';}catch(error){message(error.message);}
});
function clearPlan(){plan=null; $('plan').hidden=true; $('join-token').value=''; $('plan-commands').textContent=''; $('module-command').textContent='';}
$('clear-plan').onclick=clearPlan;
$('download-plan').onclick=()=>{if(!plan)return; const blob=new Blob(['#!/usr/bin/env bash\nset -Eeuo pipefail\n'+plan.commands.join('\n')+'\n'],{type:'text/x-shellscript'});const url=URL.createObjectURL(blob),a=document.createElement('a');a.href=url;a.download=plan.execute_on+'-setup.sh';a.click();URL.revokeObjectURL(url);message('Script contains a join credential when joining. Transfer it securely and remove it after use.');};
$('network-form').addEventListener('submit',async e=>{e.preventDefault();try{await api('/vpn/networks','POST',{name:$('network-name').value});$('network-name').value='';await refreshNetworks();message('Network metadata saved. No VPN changes were applied.');}catch(error){message(error.message);}});
async function member(remove){try{await api('/vpn/networks/'+encodeURIComponent($('member-network').value)+'/members',remove?'DELETE':'POST',{email:$('member-email').value});await refreshNetworks();message('Membership metadata updated; VPN enforcement is not implemented.');}catch(e){message(e.message);}}
$('member-form').addEventListener('submit',e=>{e.preventDefault();member(false);});
$('remove-member').onclick=()=>member(true);

$('download-config').onclick=()=>{if(!plan)return;const url=URL.createObjectURL(new Blob([plan.config_yaml],{type:'text/yaml'}));const a=document.createElement('a');a.href=url;a.download=plan.config_filename;a.click();URL.revokeObjectURL(url);message('Node config downloaded. A worker config contains a join token; remove the file after use.');};

let remoteTargets = [], remoteJob = null, remoteTimer = null;
function selectedRemoteTarget() {
  const target = remoteTargets.find(t => t.name === $('remote-target').value);
  $('remote-address').value = target?.host || '';
}
async function refreshRemote() {
  try {
    const data = await api('/remote/targets'); remoteTargets = data.targets;
    $('remote-target').replaceChildren();
    for (const t of remoteTargets) {
      const option = document.createElement('option'); option.value=t.name;
      option.textContent=t.name + ' / ' + t.host; $('remote-target').append(option);
    }
    selectedRemoteTarget();
    $('remote-status').textContent = data.enabled ? 'SSH execution enabled for configured targets only.' : 'Disabled. Configure remote_execution_enabled and ssh_targets in dashboard-dev/config.yaml, then restart the dashboard.';
    $('remote-submit').disabled = !data.enabled || !remoteTargets.length || !!remoteJob;
    $('remote-check').disabled = !data.enabled || !remoteTargets.length;
  } catch(e) { message(e.message); }
}
$('remote-target').onchange=selectedRemoteTarget;
$('remote-check').onclick=async()=>{
  try { const result=await api('/remote/targets/'+encodeURIComponent($('remote-target').value)+'/check','POST');
    message('SSH and snap/sudo prerequisites ready: '+result.host);
  } catch(e) { message(e.message); }
};
async function pollRemoteJob() {
  if (!remoteJob) return;
  try {
    const data=await api('/remote/jobs/'+remoteJob);
    $('remote-job-status').textContent=data.target + ': ' + data.state;
    $('remote-logs').textContent=data.logs.join('\n\n');
    if(data.state==='running') { remoteTimer=setTimeout(pollRemoteJob,2000); }
    else { remoteJob=null; $('remote-submit').disabled=false; refreshNodes(); }
  } catch(e) {
    message(e.message+' Polling stopped; a remote job may still be running.');
    $('remote-job-status').textContent='Status unavailable. Inspect the worker before retrying.';
    // Keep submit disabled so a lost connection cannot trigger a duplicate job.
  }
}
$('remote-form').addEventListener('submit', async e=>{
  e.preventDefault(); if(remoteJob)return;
  $('remote-submit').disabled=true;
  try {
    const result=await api('/remote/targets/'+encodeURIComponent($('remote-target').value)+'/join','POST',{
      node_name:$('remote-node').value,address:$('remote-address').value,token:$('remote-token').value
    });
    $('remote-token').value=''; $('remote-confirm').checked=false;
    remoteJob=result.job_id; $('remote-job-status').textContent='Job '+remoteJob+' started';
    pollRemoteJob();
  } catch(e) { message(e.message); $('remote-submit').disabled=false; }
});

let commandInputs={}, commandPreview=null, commandShown=0;
async function refreshCommandRoutes() {
  try {
    const data=await api('/setup/command-routes');
    const previous=$('command-route').value;
    $('command-route').replaceChildren();
    for(const route of data.routes) {
      const option=document.createElement('option');option.value=route.action;
      option.textContent=route.label+' ('+route.action+')';$('command-route').append(option);
    }
    if(data.routes.some(r=>r.action===previous))$('command-route').value=previous;
  } catch(e) {message(e.message);}
}
function clearCommands() {
  commandInputs={};commandPreview=null;commandShown=0;
  $('command-entry').textContent='';$('command-trace').textContent='';
  $('command-steps').replaceChildren();$('command-question').hidden=true;
  $('command-answer').value='';$('command-next').hidden=true;
  $('command-status').textContent='';
}
function showCommandSteps() {
  $('command-steps').replaceChildren();
  for(const [i,step] of commandPreview.steps.slice(0,commandShown).entries()) {
    const article=document.createElement('article'),title=document.createElement('h3'),source=document.createElement('small'),pre=document.createElement('pre'),button=document.createElement('button');
    title.textContent='Step '+(i+1);source.textContent=step.source+':'+step.line;
    pre.textContent=step.command;button.type='button';button.className='secondary';button.textContent='Copy command';
    button.onclick=async()=>{try{await navigator.clipboard.writeText(step.command);message('Command copied.');}catch(e){message('Select and copy the command text manually.');}};
    article.append(title,source,pre,button);$('command-steps').append(article);
  }
  $('command-next').hidden=commandShown>=commandPreview.steps.length;
  $('command-question').hidden=commandShown<commandPreview.steps.length || !commandPreview.question;
}
async function loadCommands(reset=false) {
  if(reset)clearCommands();
  try {
    commandPreview=await api('/setup/command-preview','POST',{action:$('command-route').value,inputs:commandInputs});
    $('command-entry').textContent=commandPreview.entry_command;
    $('command-trace').textContent=commandPreview.trace.map(t=>t.source+':'+t.line+'\n'+t.call+(t.note?'\n'+t.note:'')).join('\n\n');
    $('command-status').textContent=commandPreview.limitation?'Preview stopped: '+commandPreview.limitation : commandPreview.complete?'Route resolved. Reveal commands below in order.':'More selection or runtime input is needed.';
    const q=commandPreview.question;
    if(q) {
      $('command-question-label').textContent=q.label;
      $('command-choice').replaceChildren();
      if(q.choices) for(const value of q.choices) {const option=document.createElement('option');option.value=value;option.textContent=value;$('command-choice').append(option);}
      $('command-choice').hidden=!q.choices;$('command-answer').hidden=!!q.choices;
      $('command-answer').type=q.secret?'password':'text';$('command-answer').value='';
    }
    if(commandShown<commandPreview.steps.length)commandShown++;
    showCommandSteps();
  } catch(e) {message(e.message);}
}
$('command-load').onclick=()=>loadCommands(true);
$('command-reset').onclick=clearCommands;
$('command-route').onchange=clearCommands;
$('command-next').onclick=()=>{commandShown++;showCommandSteps();};
$('command-question').addEventListener('submit',e=>{
  e.preventDefault();const q=commandPreview?.question;if(!q)return;
  commandInputs[q.key]=q.choices?$('command-choice').value:$('command-answer').value;
  $('command-answer').value='';loadCommands();
});

async function refreshEnrollment() {
  try {
    const networks=await api('/vpn/networks');$('invite-network').replaceChildren();
    for(const n of networks.networks){const option=document.createElement('option');option.value=n.name;option.textContent=n.name;$('invite-network').append(option);}
    const data=await api('/enrollment/devices');$('enrollment-devices').replaceChildren();
    for(const d of data.devices) {
      const article=document.createElement('article'),title=document.createElement('h3'),summary=document.createElement('p'),pre=document.createElement('pre'),review=document.createElement('button'),apply=document.createElement('button'),label=document.createElement('label'),check=document.createElement('input'),revoke=document.createElement('button');
      article.className='card';title.textContent=d.node_name+' / '+d.user_code;
      summary.textContent=d.email+' · '+d.network+' · '+d.state+(d.address?' · '+d.address:'');
      review.textContent='Review peer commands';review.type='button';review.className='secondary';
      check.type='checkbox';label.append(check,document.createTextNode(' I authorize applying this reviewed VPN peer.'));
      apply.textContent='Apply approved peer';apply.type='button';apply.disabled=true;
      let reviewed=false;
      check.onchange=()=>{apply.disabled=!reviewed||!check.checked;};
      review.onclick=async()=>{try{const plan=await api('/vpn/peers/'+d.user_code+'/approve','POST',{apply:false});pre.textContent=plan.commands.join('\n')+'\n'+plan.note;reviewed=true;apply.disabled=!check.checked;}catch(e){message(e.message);}};
      apply.onclick=async()=>{try{await api('/vpn/peers/'+d.user_code+'/approve','POST',{apply:true});message('Peer applied and saved on the dedicated WireGuard hub.');refreshEnrollment();}catch(e){message(e.message);}};
      revoke.textContent='Revoke invitation / VPN peer';revoke.type='button';revoke.className='secondary';
      revoke.onclick=async()=>{try{const result=await api('/enrollment/invitations/'+d.invitation_id,'DELETE');message(result.note);refreshEnrollment();}catch(e){message(e.message);}};
      const cleanup=document.createElement('button');cleanup.type='button';cleanup.className='secondary';cleanup.textContent='Worker uninstall commands';
      cleanup.onclick=async()=>{try{const result=await api('/enrollment/uninstall-plan','POST',{node_name:d.node_name});pre.textContent=JSON.stringify(result,null,2);}catch(e){message(e.message);}};
      article.append(title,summary,review,pre,label,apply,cleanup,revoke);$('enrollment-devices').append(article);
    }
    if(!data.devices.length)$('enrollment-devices').textContent='No workers have started device authorization yet.';
    const invitations=await api('/enrollment/invitations');$('enrollment-invitations').replaceChildren();
    for(const invitation of invitations.invitations){const div=document.createElement('div'),text=document.createElement('p'),button=document.createElement('button');text.textContent=invitation.node_name+' / '+invitation.email+' / '+invitation.state+' / expires '+new Date(invitation.expires*1000).toLocaleString();button.type='button';button.className='secondary';button.textContent='Revoke invitation / peer';button.disabled=invitation.state==='revoked';button.onclick=async()=>{try{const result=await api('/enrollment/invitations/'+invitation.id,'DELETE');message(result.note);refreshEnrollment();}catch(e){message(e.message);}};div.append(text,button);$('enrollment-invitations').append(div);}

  } catch(e){message(e.message);}
}
$('invite-form').onsubmit=async e=>{e.preventDefault();try{const data=await api('/enrollment/invitations','POST',{email:$('invite-email').value,node_name:$('invite-node').value,network:$('invite-network').value,minutes:Number($('invite-minutes').value)});$('invite-result').textContent='Invitation code: '+data.invitation_code+'\n\n'+data.command+'\n\n'+data.note;$('invite-link-text').textContent='Worker link: '+data.link;}catch(e){message(e.message);}};
$('enrollment-refresh').onclick=refreshEnrollment;
$('hub-plan').onclick=async()=>{try{const plan=await api('/vpn/hub-plan');$('hub-commands').textContent=plan.commands.join('\n\n')+'\n\n'+plan.note;}catch(e){message(e.message);}};
$('storage-form').onsubmit=async e=>{e.preventDefault();try{const plan=await api('/storage/plan','POST',{mode:$('storage-mode').value,name:$('storage-name').value,path:$('storage-path').value,source:$('storage-source').value,mountpoint:$('storage-mountpoint').value,server:$('storage-server').value,clients:[...$('storage-clients').querySelectorAll('input:checked')].map(x=>x.value),access:$('storage-access-mode').value,user:$('storage-user').value});$('storage-note').textContent='Run on: '+plan.execute_on+'. '+plan.note;$('storage-commands').textContent=plan.commands.join('\n\n');$('storage-volume').textContent=plan.kubernetes_volume?JSON.stringify(plan.kubernetes_volume,null,2):'';}catch(e){message(e.message);}};

$('storage-mode').onchange=()=>{storageAccessMode();if($('storage-mode').value==='rsync' && $('storage-path').value==='/srv/model-cache/huggingface')$('storage-path').value='/srv/model-cache/huggingface/hub';else if($('storage-mode').value!=='rsync' && $('storage-path').value==='/srv/model-cache/huggingface/hub')$('storage-path').value='/srv/model-cache/huggingface';};

$('invite-clear').onclick=()=>{$('invite-result').textContent='';$('invite-link-text').textContent='';};

function storageAccessMode(){
  $('storage-access').hidden=$('storage-mode').value!=='export';
  const all=$('storage-access-mode').value==='all-vpn';
  $('storage-node-picker').hidden=all;$('storage-all-note').hidden=!all;
}
async function refreshStorageClients(){
  try{
    const previous=new Set([...$('storage-clients').querySelectorAll('input:checked')].map(x=>x.value));
    const data=await api('/storage/clients');$('storage-clients').replaceChildren();
    for(const node of data.clients){
      const label=document.createElement('label'),checkbox=document.createElement('input');
      checkbox.type='checkbox';checkbox.value=node.address;checkbox.checked=previous.has(node.address);
      label.append(checkbox,document.createTextNode(node.name+' / '+node.address+' · '+node.source));
      $('storage-clients').append(label);
    }
    $('storage-client-status').textContent=(data.clients.length?data.clients.length+' VPN addresses available.':'No VPN nodes available yet.')+(data.inventory_note?' '+data.inventory_note:'');
    $('storage-all-note').textContent='Allow all addresses in '+data.vpn_pool+', including future peers. Review the export and restrict TCP 2049 to the VPN.';
  }catch(e){$('storage-client-status').textContent=e.message;}
}
$('storage-refresh-clients').onclick=refreshStorageClients;
$('storage-select-all').onclick=()=>{$('storage-clients').querySelectorAll('input').forEach(x=>x.checked=true);};
$('storage-select-none').onclick=()=>{$('storage-clients').querySelectorAll('input').forEach(x=>x.checked=false);};
$('storage-access-mode').onchange=storageAccessMode;
storageAccessMode();

$('plan-ssh').onclick=async()=>{
  if(!plan || document.querySelector('input[name=mode]:checked').value!=='join')return;
  setupTab='remote';view('tooling');
  $('remote-node').value=$('node-name').value;
  $('remote-token').value=$('join-token').value;
  $('remote-confirm').checked=false;
  message('Node name and token copied to SSH execution. Select the configured target, verify its address, and review before executing.');
};

function updateClusterContext(){
  $('invite-cluster').replaceChildren();
  const local=workspaceClusters.find(c=>c.id===localCluster);
  if(local){const option=document.createElement('option');option.value=local.id;option.textContent=local.name;$('invite-cluster').append(option);}
}
async function refreshWorkspaceClusters(){
  const data=await api('/workspaces/clusters');workspaceClusters=data.clusters;localCluster=data.local_cluster;
  selectedCluster=workspaceClusters.some(c=>c.id===selectedCluster)?selectedCluster:localCluster;
  for(const id of ['workspace-cluster','workspace-invite-cluster']){
    $(id).replaceChildren();
    for(const cluster of workspaceClusters){const option=document.createElement('option');option.value=cluster.id;option.textContent=cluster.name+(cluster.local?' · this host':'');$(id).append(option);}
  }
  $('workspace-cluster').value=selectedCluster;$('workspace-cluster').disabled=false;updateClusterContext();
}
$('workspace-cluster').onchange=()=>{
  selectedCluster=$('workspace-cluster').value;
  $('nodes').replaceChildren();for(const id of ['total','workers','gpus'])$(id).textContent='—';
  clearPlan();$('remote-token').value='';view('overview');refreshNodes();
};
$('workspace-invite-form').onsubmit=async event=>{event.preventDefault();try{
  const data=await api('/workspaces/invitations','POST',{email:$('workspace-invite-email').value,cluster_id:$('workspace-invite-cluster').value,role:$('workspace-invite-role').value});
  $('workspace-invite-result').textContent=data.link+'\nCode: '+data.code+'\n'+data.note;
}catch(e){message(e.message);}};
