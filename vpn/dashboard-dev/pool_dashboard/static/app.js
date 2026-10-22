'use strict';
let accessToken = '', plan = null;
const $ = id => document.getElementById(id);
const titles = {overview:'Cluster overview', wizard:'Node setup wizard', vpn:'VPN workbench', modules:'Setup modules'};
const message = text => { $('message').textContent = text || ''; };
async function api(path, method='GET', body) {
  const response = await fetch('/api/v1' + path, {method, cache:'no-store', headers: {
    'Authorization':'Bearer ' + accessToken, 'Content-Type':'application/json'
  }, ...(body ? {body:JSON.stringify(body)} : {})});
  const data = await response.json();
  if (!response.ok) throw new Error(typeof data.detail === 'string' ? data.detail : 'Check the form fields and try again.');
  return data;
}
function cell(row, text) { const element = document.createElement('td'); element.textContent = text; row.append(element); }
async function refreshNodes() {
  try {
    const {nodes} = await api('/cluster/nodes');
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
function view(name) {
  document.querySelectorAll('.view').forEach(v=>v.hidden=v.id!==name);
  document.querySelectorAll('nav button').forEach(b=>b.classList.toggle('active',b.dataset.view===name));
  $('page-title').textContent=titles[name]; message('');
  if(accessToken && name==='vpn') refreshNetworks();
  if(accessToken && name==='modules') refreshModules();
}
document.querySelectorAll('[data-view]').forEach(b=>b.addEventListener('click',()=>view(b.dataset.view)));
$('access-form').addEventListener('submit',async e=>{e.preventDefault(); accessToken=$('access-token').value; $('access-token').value='';
  try {await api('/setup/modules'); $('access').hidden=true; await refreshNodes();} catch(error){accessToken='';message(error.message);}
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
  try {plan=await api('/setup/'+mode,'POST',body); $('plan').hidden=false; $('plan-note').textContent=`Run on: ${plan.execute_on}. ${plan.note}`; $('plan-commands').textContent=plan.commands.join('\n'); $('module-command').textContent=plan.module_command; $('download-plan').textContent=mode==='join'?'Download worker script':'Download control-plane script';}catch(error){message(error.message);}
});
function clearPlan(){plan=null; $('plan').hidden=true; $('join-token').value=''; $('plan-commands').textContent=''; $('module-command').textContent='';}
$('clear-plan').onclick=clearPlan;
$('download-plan').onclick=()=>{if(!plan)return; const blob=new Blob(['#!/usr/bin/env bash\nset -Eeuo pipefail\n'+plan.commands.join('\n')+'\n'],{type:'text/x-shellscript'});const url=URL.createObjectURL(blob),a=document.createElement('a');a.href=url;a.download=plan.execute_on+'-setup.sh';a.click();URL.revokeObjectURL(url);message('Script contains a join credential when joining. Transfer it securely and remove it after use.');};
$('network-form').addEventListener('submit',async e=>{e.preventDefault();try{await api('/vpn/networks','POST',{name:$('network-name').value});$('network-name').value='';await refreshNetworks();message('Network metadata saved. No VPN changes were applied.');}catch(error){message(error.message);}});
async function member(remove){try{await api('/vpn/networks/'+encodeURIComponent($('member-network').value)+'/members',remove?'DELETE':'POST',{email:$('member-email').value});await refreshNetworks();message('Membership metadata updated; VPN enforcement is not implemented.');}catch(e){message(e.message);}}
$('member-form').addEventListener('submit',e=>{e.preventDefault();member(false);});
$('remove-member').onclick=()=>member(true);

$('download-config').onclick=()=>{if(!plan)return;const url=URL.createObjectURL(new Blob([plan.config_yaml],{type:'text/yaml'}));const a=document.createElement('a');a.href=url;a.download=plan.config_filename;a.click();URL.revokeObjectURL(url);message('Node config downloaded. A worker config contains a join token; remove the file after use.');};
