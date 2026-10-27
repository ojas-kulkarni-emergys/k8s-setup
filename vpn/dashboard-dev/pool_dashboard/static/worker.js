'use strict';
const el=id=>document.getElementById(id);
const base=new URL('../',window.location.href);base.hash='';base.search='';
const fragment=new URLSearchParams(window.location.hash.slice(1));
el('worker-invite').value=fragment.get('invite')||'';
el('worker-code').value=fragment.get('code')||'';
history.replaceState(null,'',window.location.pathname);
const say=text=>{el('worker-message').textContent=text;};
async function api(path,body) {
  const response=await fetch(new URL('api/v1/enroll'+path,base),{method:'POST',credentials:'same-origin',cache:'no-store',headers:{'Content-Type':'application/json'},body:JSON.stringify(body)});
  const data=await response.json();if(!response.ok)throw new Error(typeof data.detail==='string'?data.detail:'Check the supplied fields.');return data;
}
function account(){return {email:el('worker-email').value,password:el('worker-password').value,invitation:el('worker-invite').value};}
el('worker-login').onsubmit=async e=>{e.preventDefault();try{await api('/login',account());el('worker-password').value='';say('Signed in. Review the device code before authorizing. Your cluster overview is available from My clusters.');}catch(e){say(e.message);}};
el('worker-register').onclick=async()=>{try{await api('/register',account());say('Invited account created. Sign in to continue.');}catch(e){say(e.message);}};
el('worker-logout').onclick=async()=>{try{await api('/logout',{});el('worker-authorize').disabled=true;el('worker-details').textContent='';say('Signed out.');}catch(e){say(e.message);}};
let reviewedCode=null;
el('worker-code').oninput=()=>{reviewedCode=null;el('worker-authorize').disabled=true;};
el('worker-review').onsubmit=async e=>{e.preventDefault();try{const code=el('worker-code').value.toUpperCase();const data=await api('/device-info',{user_code:code});reviewedCode=code;el('worker-details').textContent=JSON.stringify(data,null,2);el('worker-authorize').disabled=data.state!=='pending';}catch(e){say(e.message);}};
el('worker-authorize').onclick=async()=>{if(!reviewedCode)return;try{await api('/authorize',{user_code:reviewedCode});el('worker-authorize').disabled=true;say('Device authenticated. Wait for administrator VPN approval, then continue in your terminal.');}catch(e){say(e.message);}};
const shell=value=>"'"+String(value).replaceAll("'","'\\''")+"'";
el('worker-command').onclick=()=>{if(!el('worker-invite').value){say('Enter the invitation from your administrator.');return;}el('worker-command-text').textContent='curl --fail --show-error --silent '+shell(new URL('join.sh',base).href)+' -o join.sh && bash join.sh --server '+shell(base.href.replace(/\/$/,''))+' --invite '+shell(el('worker-invite').value)+'\n# Add --execute only after reviewing the script and authorizing local changes.';};
