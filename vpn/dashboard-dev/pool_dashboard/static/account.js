'use strict';
const el=id=>document.getElementById(id),base=new URL('../',location.href);
const params=new URLSearchParams(location.hash.slice(1));el('account-invitation').value=params.get('invite')||'';
history.replaceState(null,'',location.pathname);
let workspace=null;
const say=text=>el('account-message').textContent=text;
async function api(path,body){
 const response=await fetch(new URL('api/v1/enroll'+path,base),{method:body?'POST':'GET',credentials:'same-origin',cache:'no-store',headers:{'Content-Type':'application/json'},...(body?{body:JSON.stringify(body)}:{})});
 const data=await response.json();if(!response.ok)throw new Error(typeof data.detail==='string'?data.detail:'Check your form values.');return data;
}
function clearOverview(){el('account-nodes').replaceChildren();for(const id of ['account-total','account-ready','account-gpus'])el(id).textContent='—';}
async function overview(){
 clearOverview();const id=el('account-cluster').value,cluster=workspace?.clusters.find(c=>c.id===id);
 el('account-owner').hidden=cluster?.role!=='owner';el('account-role').textContent=cluster?'Your access: '+cluster.role:'';
 el('account-share-result').textContent='';if(!id)return;
 try{const data=await api('/workspace/clusters/'+encodeURIComponent(id)+'/nodes');
 if(el('account-cluster').value!==id)return;
 for(const node of data.nodes){const tr=document.createElement('tr');for(const value of [node.name,node.roles.join(', '),node.ready?'Ready':'Not ready',node.addresses.find(a=>a.type==='InternalIP')?.address||'—',(node.cpu||'—')+' / '+(node.memory||'—'),node.gpu]){const td=document.createElement('td');td.textContent=value;tr.append(td);}el('account-nodes').append(tr);}
 el('account-total').textContent=data.nodes.length;el('account-ready').textContent=data.nodes.filter(n=>n.ready).length;el('account-gpus').textContent=data.nodes.reduce((n,x)=>n+(Number(x.gpu)||0),0);
 }catch(e){say(e.message);}
}
async function load(){
 workspace=await api('/workspace/me');el('account-auth').hidden=true;el('account-workspace').hidden=false;el('account-identity').textContent=workspace.email;
 const selected=el('account-cluster').value;el('account-cluster').replaceChildren();
 for(const cluster of workspace.clusters){const o=document.createElement('option');o.value=cluster.id;o.textContent=cluster.name+' / '+cluster.role;el('account-cluster').append(o);}
 if(workspace.clusters.some(c=>c.id===selected))el('account-cluster').value=selected;
 el('account-machines').replaceChildren();for(const machine of workspace.machines){const p=document.createElement('p');p.textContent=machine.hostname+' · '+machine.cluster_id+' · '+machine.role;el('account-machines').append(p);}
 if(!workspace.machines.length)el('account-machines').textContent='No registered machines for this account yet.';
 say(workspace.clusters.length?'Signed in. Select a cluster to view.':'Signed in. Accept a cluster invitation or complete worker approval.');await overview();
}
el('account-login').onsubmit=async event=>{event.preventDefault();try{await api('/login',{email:el('account-email').value,password:el('account-password').value});el('account-password').value='';await load();}catch(e){say(e.message);}};
el('account-register').onclick=async()=>{try{await api('/workspace/register',{email:el('account-email').value,password:el('account-password').value,invitation:el('account-invitation').value});el('account-password').value='';say('Account created. Sign in and accept the invitation.');}catch(e){say(e.message);}};
el('account-accept').onclick=async()=>{try{await api('/workspace/accept',{invitation:el('account-invitation').value});el('account-invitation').value='';await load();}catch(e){say(e.message);}};
el('account-share').onsubmit=async event=>{event.preventDefault();try{const data=await api('/workspace/invitations',{email:el('account-share-email').value,cluster_id:el('account-cluster').value,role:el('account-share-role').value});el('account-share-result').textContent=data.link+'\n'+data.note;}catch(e){say(e.message);}};
el('account-cluster').onchange=overview;el('account-refresh').onclick=overview;
el('account-logout').onclick=async()=>{try{await api('/logout',{});workspace=null;el('account-workspace').hidden=true;el('account-auth').hidden=false;clearOverview();el('account-machines').replaceChildren();el('account-share-result').textContent='';say('Signed out.');}catch(e){say(e.message);}};
load().catch(()=>say('Sign in to view your clusters.'));
