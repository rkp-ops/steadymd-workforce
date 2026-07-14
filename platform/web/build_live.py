#!/usr/bin/env python3
"""Assemble console2-live.html: the reworked console + Supabase auth gate with
sign-in, forgot-password (email reset link), and set-new-password (recovery)."""
import os
ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
tpl = open(os.path.join(ROOT, "platform/web/console.tpl.html")).read()

AUTH_CSS = """
  .authgate{position:fixed;inset:0;z-index:100;background:var(--bg);display:flex;align-items:center;justify-content:center;padding:20px}
  .authgate.hide{display:none}
  .authcard{background:var(--surface);border:1px solid var(--border);border-radius:16px;box-shadow:var(--shadow);padding:28px 28px 24px;width:100%;max-width:378px}
  .authcard h2{font-size:20px;font-weight:680;letter-spacing:-.02em;margin:5px 0 3px}
  .authcard .lead{color:var(--ink-2);font-size:12.5px;margin-bottom:16px;line-height:1.5}
  .authcard label{display:block;font-size:10.5px;font-weight:700;letter-spacing:.07em;text-transform:uppercase;color:var(--ink-3);margin:12px 0 5px}
  .authcard input{width:100%;height:38px;border:1px solid var(--border-2);background:var(--bg);color:var(--ink);border-radius:9px;padding:0 12px;font:inherit;font-size:14px}
  .authbtn{width:100%;height:40px;margin-top:18px;border:0;border-radius:9px;background:var(--accent);color:#fff;font:inherit;font-size:14px;font-weight:650;cursor:pointer}
  .authbtn:hover{filter:brightness(1.06)}.authbtn:disabled{opacity:.55;cursor:default}
  .autherr{color:var(--bad);font-size:12.5px;margin-top:12px;min-height:16px;line-height:1.4}
  .linkbtn{appearance:none;background:0;border:0;color:var(--accent-ink);font:inherit;font-size:12.5px;cursor:pointer;padding:10px 0 0;text-decoration:underline;display:inline-block}
  .linkbtn:hover{opacity:.8}
  .spin{display:inline-block;width:15px;height:15px;border:2px solid rgba(255,255,255,.4);border-top-color:#fff;border-radius:50%;animation:sp .7s linear infinite;vertical-align:-2px}
  @keyframes sp{to{transform:rotate(360deg)}}
</style>"""
tpl = tpl.replace("</style>", AUTH_CSS, 1)

AUTH_MARKUP = """<div id="authgate" class="authgate">
  <div class="authcard">
    <div class="eyebrow">SteadyMD · Operational Intelligence</div>
    <h2>Operations Console</h2>
    <div id="authbody"><div class="lead">Loading…</div></div>
  </div>
</div>

<div class="wrap">"""
tpl = tpl.replace('<div class="wrap">', AUTH_MARKUP, 1)

tpl = tpl.replace(
    '<button class="ghost" id="export">↧ Export</button>',
    '<button class="ghost" id="export">↧ Export</button>\n      <button class="ghost" id="signout" style="display:none">⎋ Sign out</button>', 1)

AUTH_JS = r"""
<script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/dist/umd/supabase.min.js"></script>
<script>
(function(){
  const SB_URL='https://eeszygextbqglayglvfm.supabase.co', SB_KEY='sb_publishable_txIrKbYtv9kjSKXjQVJFbw_hzUsLNEK';
  const gate=document.getElementById('authgate'), body=document.getElementById('authbody');
  if(!window.supabase){ body.innerHTML='<div class="lead">Couldn’t load the sign-in library (network blocked). Reload to retry.</div>'; return; }
  const sb=window.supabase.createClient(SB_URL,SB_KEY,{auth:{persistSession:true,autoRefreshToken:true,detectSessionInUrl:true}}); window.__sb=sb;
  const H=s=>String(s==null?'':s).replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
  const mapRoster=r=>({rid:r.id,n:r.name,c:r.credential||'',tier:r.tier||null,needs:r.needs||[],npi:r.npi||'',em:r.emails||[],al:r.aliases||[],ls:r.license_states||[],as:r.active_states||[],pr:r.programs||[],pa:r.partners||[],mo:r.modalities||[],ct:r.consult_count||0,sh:Number(r.shift_hours)||0,inc:Number(r.incentive_usd)||0,la:r.last_active||'',st:r.status});
  async function whoami(){try{const {data:{user}}=await sb.auth.getUser();return (user&&user.email)||'';}catch(_){return '';}}

  async function load(){
    const [a,b,c,d,e,f,g,rvk]=await Promise.all([sb.rpc('sli_dataset'),sb.rpc('consult_summary'),sb.from('clinician_roster').select('*'),sb.rpc('shift_summary'),sb.rpc('incentive_summary'),sb.rpc('vph_trend'),sb.rpc('coverage_grid'),sb.rpc('review_acks')]);
    const er=a.error||b.error||c.error||d.error||e.error;
    if(er){ if(String(er.code)==='42501'||/not authorized/i.test(er.message||'')){ denied(await whoami()); return; } body.innerHTML='<div class="lead">Signed in, but the data didn’t load: '+H(er.message||'unknown error')+'</div><button type="button" class="linkbtn" id="a-out">Sign out</button>'; document.getElementById('a-out').onclick=async()=>{await sb.auth.signOut();location.reload();}; return; }
    window.__init(a.data,b.data,(c.data||[]).map(mapRoster),d.data,e.data,(f&&!f.error)?f.data:null,(g&&!g.error)?g.data:null,(rvk&&!rvk.error)?rvk.data:null); // vph + coverage + review acks are non-fatal: each tab shows its empty state if the RPC is unavailable
    if(window.__setReviewApi){ window.__setReviewApi({ // any active app_user can triage; every ack records who
      list:  async()=>{ const r=await sb.rpc('review_acks'); if(r.error) throw new Error(r.error.message||'load failed'); return r.data; },
      set:   async(k,cat,subj,note)=>{ const r=await sb.rpc('set_review_ack',{p_flag_key:k,p_category:cat,p_subject:subj||null,p_note:note||null}); if(r.error) throw new Error(r.error.message||'save failed'); return r.data; },
      clear: async(k)=>{ const r=await sb.rpc('clear_review_ack',{p_flag_key:k}); if(r.error) throw new Error(r.error.message||'save failed'); return r.data; },
    }); }
    sb.rpc('whoami').then(async ({data,error})=>{ const admin=!error&&data&&data.is_admin;
      if(window.__setRosterAdmin){
        const onAdd = admin?(async(row,confirm)=>{ const r=await sb.rpc('set_roster_membership',{p_roster_id:row.rid,p_confirm:confirm}); if(r.error) throw new Error(r.error.message||'update failed'); return r.data; }):null;
        const onEdit = admin?(async(row,p)=>{ const r=await sb.rpc('edit_clinician',{p_roster_id:row.rid,p_credential:(p.credential===undefined?null:p.credential),p_states:(p.states===undefined?null:p.states),p_remove:!!p.remove}); if(r.error) throw new Error(r.error.message||'update failed'); return r.data; }):null;
        window.__setRosterAdmin(admin, onAdd, onEdit);
      }
      if(window.__setUsersAdmin){
        if(admin){
          const api={
            list:      async()=>{ const r=await sb.rpc('admin_list_users'); if(r.error) throw new Error(r.error.message||'load failed'); return r.data; },
            provision: async(em,role,nm)=>{ const r=await sb.rpc('admin_provision_user',{p_email:em,p_role:role,p_name:nm||null}); if(r.error) throw new Error(r.error.message||'provision failed'); return r.data; },
            setRole:   async(id,role)=>{ const r=await sb.rpc('admin_set_user_role',{p_id:id,p_role:role}); if(r.error) throw new Error(r.error.message||'update failed'); return r.data; },
            setStatus: async(id,st)=>{ const r=await sb.rpc('admin_set_user_status',{p_id:id,p_status:st}); if(r.error) throw new Error(r.error.message||'update failed'); return r.data; },
          };
          let list=[]; try{ const r=await sb.rpc('admin_list_users'); if(!r.error) list=r.data; }catch(_){}
          window.__setUsersAdmin(true, api, list);
        } else { window.__setUsersAdmin(false); }
      }
    }).catch(()=>{});
    const so=document.getElementById('signout'); if(so){ so.style.display='inline-flex'; so.onclick=async()=>{await sb.auth.signOut();location.reload();}; whoami().then(m=>{if(m)so.title='Signed in as '+m;}); }
    gate.classList.add('hide');
  }
  function denied(em){ body.innerHTML='<div class="lead">You’re signed in as <b>'+H(em||'this account')+'</b>, but it isn’t provisioned for the console yet. Ask an admin to add you, then reload.</div><button type="button" class="linkbtn" id="a-out">Sign out</button>'; document.getElementById('a-out').onclick=async()=>{await sb.auth.signOut();location.reload();}; }

  function viewSignin(){
    body.innerHTML='<div class="lead">Sign in with your SteadyMD account.</div>'+
      '<label for="s-email">Email</label><input id="s-email" type="email" autocomplete="username" spellcheck="false">'+
      '<label for="s-pw">Password</label><input id="s-pw" type="password" autocomplete="current-password">'+
      '<button class="authbtn" id="s-go">Sign in</button><div class="autherr" id="s-err"></div>'+
      '<button type="button" class="linkbtn" id="s-forgot">Forgot password?</button>';
    const go=document.getElementById('s-go'), err=document.getElementById('s-err');
    go.onclick=async()=>{ const em=document.getElementById('s-email').value.trim(), pw=document.getElementById('s-pw').value; if(!em||!pw){err.textContent='Enter your email and password.';return;} err.textContent='';go.disabled=true;go.innerHTML='<span class="spin"></span>'; const {error}=await sb.auth.signInWithPassword({email:em,password:pw}); if(error){go.disabled=false;go.textContent='Sign in';err.textContent=error.message;return;} await load(); go.disabled=false;go.textContent='Sign in'; };
    document.getElementById('s-pw').addEventListener('keydown',ev=>{if(ev.key==='Enter')go.click();});
    document.getElementById('s-forgot').onclick=viewReset;
  }
  function viewReset(){
    body.innerHTML='<div class="lead">Enter your email and we’ll send a reset link.</div>'+
      '<label for="r-email">Email</label><input id="r-email" type="email" autocomplete="username" spellcheck="false">'+
      '<button class="authbtn" id="r-go">Send reset link</button><div class="autherr" id="r-err"></div>'+
      '<button type="button" class="linkbtn" id="r-back">← Back to sign in</button>';
    const go=document.getElementById('r-go'), err=document.getElementById('r-err');
    go.onclick=async()=>{ const em=document.getElementById('r-email').value.trim(); if(!em){err.textContent='Enter your email.';return;} err.textContent='';go.disabled=true;go.innerHTML='<span class="spin"></span>'; const {error}=await sb.auth.resetPasswordForEmail(em,{redirectTo:location.origin+location.pathname}); go.disabled=false;go.textContent='Send reset link'; if(error){err.textContent=error.message;return;} body.innerHTML='<div class="lead">Sent. Check <b>'+H(em)+'</b> for a reset link, open it on this device, and you’ll come back here to set a new password.</div><button type="button" class="linkbtn" id="r-back2">← Back to sign in</button>'; document.getElementById('r-back2').onclick=viewSignin; };
    document.getElementById('r-email').addEventListener('keydown',ev=>{if(ev.key==='Enter')go.click();});
    document.getElementById('r-back').onclick=viewSignin;
  }
  function viewRecovery(){
    body.innerHTML='<div class="lead">Set a new password for your account.</div>'+
      '<label for="n1">New password</label><input id="n1" type="password" autocomplete="new-password">'+
      '<label for="n2">Confirm password</label><input id="n2" type="password" autocomplete="new-password">'+
      '<button class="authbtn" id="n-go">Set password &amp; sign in</button><div class="autherr" id="n-err"></div>';
    const go=document.getElementById('n-go'), err=document.getElementById('n-err');
    go.onclick=async()=>{ const p1=document.getElementById('n1').value, p2=document.getElementById('n2').value; if(p1.length<8){err.textContent='Use at least 8 characters.';return;} if(p1!==p2){err.textContent='Passwords don’t match.';return;} err.textContent='';go.disabled=true;go.innerHTML='<span class="spin"></span>'; const {error}=await sb.auth.updateUser({password:p1}); if(error){go.disabled=false;go.textContent='Set password & sign in';err.textContent=error.message;return;} await load(); };
    document.getElementById('n2').addEventListener('keydown',ev=>{if(ev.key==='Enter')go.click();});
  }

  sb.auth.onAuthStateChange((event)=>{ if(event==='PASSWORD_RECOVERY') viewRecovery(); });
  viewSignin();
  (async()=>{
    if((location.hash||'').indexOf('type=recovery')>-1) return; // recovery handler takes over
    try{ const {data:{session}}=await sb.auth.getSession(); if(session) await load(); }catch(_){}
  })();
})();
</script>"""
tpl = tpl.rstrip() + "\n" + AUTH_JS + "\n"

doc = '<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>SteadyMD Operations Console</title></head><body>\n' + tpl + "\n</body></html>\n"
open(os.path.join(ROOT, "public/console-live.html"), "w").write(doc)   # workforce site: /console-live.html
# dedicated standalone home — steadymd-operational.netlify.app serves operational/index.html at root
op = os.path.join(ROOT, "operational"); os.makedirs(op, exist_ok=True)
open(os.path.join(op, "index.html"), "w").write(doc)
print("wrote public/console-live.html + operational/index.html", len(doc))
for k in ("resetPasswordForEmail","PASSWORD_RECOVERY","viewRecovery","s-forgot","updateUser",
          "__setRosterAdmin","set_roster_membership","whoami","rid:r.id","Confirm onto roster",
          "edit_clinician","tierBadge","NEEDS-CORRECTION","editbar","Coverage seats","tier:r.tier",
          "vph_trend","renderVph",'data-tab="productivity"',"Scheduled, no consults","vphModel",
          "coverage_grid","renderCoverage",'data-tab="coverage"',"covHeat","DOWL7",
          "__setUsersAdmin","renderUsers",'data-tab="users"',"admin_provision_user",
          "admin_set_user_status","Provision access","How access works",
          "review_acks","set_review_ack","reviewFlags","renderReview",'data-tab="review"',
          "__setReviewApi","Needs a look","flagRowHTML",
          "guideSel","Keeping the data current","Is this real-time?"):
    assert k in doc, k
print("checks ok")
