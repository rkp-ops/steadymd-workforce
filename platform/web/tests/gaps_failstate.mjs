// The bug this guards: a failed / unwired / empty RPC left GAPS.rows empty and
// the page rendered "Every state is covered for every hour in this window."
// A failure must read as a failure. Never as safety.
import pw from '/opt/node22/lib/node_modules/playwright/index.js';
const {chromium}=pw; import {pathToFileURL} from 'url';
import {resolve,dirname} from 'path'; import {fileURLToPath} from 'url';
const PAGE=resolve(dirname(fileURLToPath(import.meta.url)),'../../../public/console-live.html');
let pass=0,fail=0; const ok=(c,m)=>{c?(pass++,console.log('PASS '+m)):(fail++,console.log('FAIL '+m))};
const b=await chromium.launch(); const p=await b.newPage({viewport:{width:1320,height:900}});
const errs=[]; p.on('pageerror',e=>errs.push(e.message));
await p.goto(pathToFileURL(PAGE).href,{waitUntil:'domcontentloaded'}); await p.waitForTimeout(250);
await p.evaluate(()=>{document.getElementById('authgate')?.classList.add('hide');
  window.__init([['Amazon','UTI','TX','async_messaging',true,60,3,10,'2026-07-16']],null,[],
  {loaded:{min:'2026-05-31',max:'2026-08-31'},range:{min:'2026-05-31',max:'2026-08-31'},
   by_service_line:[{name:'Daytime Clinical Service Line',hours:8,shifts:1}],by_cred:[],top_clin:[],
   total_hours:8,n_shifts:1,n_clinicians:1},null,null,null,null,null,[]);});

const probe=()=>p.evaluate(()=>({
  hero:($('#gapHero')||{}).textContent||'',
  whenHidden:$('#gapWhenCard').classList.contains('hide'),
  tlHidden:$('#gapTlCard').classList.contains('hide'),
  hasRetry:!!$('#gapRetry')}));

// 1. RPC returns a PostgREST-style error
await p.evaluate(()=>{window.__setRangeApi({stateGaps:()=>Promise.resolve({error:{message:'permission denied for function state_gap_windows'}})});window.__kickGaps()});
await p.waitForTimeout(300); let r=await probe();
ok(!/Every state is covered/.test(r.hero),'RPC error does NOT render as all-clear');
ok(/could not be checked/i.test(r.hero),`RPC error states the failure (${r.hero.trim().slice(0,60)})`);
ok(/permission denied/.test(r.hero),'the real server message is shown, not swallowed');
ok(r.hasRetry,'a retry control is offered');
ok(r.whenHidden&&r.tlHidden,'no empty result cards are left on screen');

// 2. RPC throws
await p.evaluate(()=>{window.__setRangeApi({stateGaps:()=>Promise.reject(new Error('NetworkError: failed to fetch'))});
  GW._init=0;window.__kickGaps()});
await p.waitForTimeout(300); r=await probe();
ok(!/Every state is covered/.test(r.hero),'thrown exception does NOT render as all-clear');
ok(/failed to fetch/.test(r.hero),'the thrown message reaches the operator');

// 3. RPC resolves with no payload at all
await p.evaluate(()=>{window.__setRangeApi({stateGaps:()=>Promise.resolve({})});GW._init=0;window.__kickGaps()});
await p.waitForTimeout(300); r=await probe();
ok(!/Every state is covered/.test(r.hero),'empty payload does NOT render as all-clear');

// 4. a GENUINE zero-gap result still reads as covered
await p.evaluate(()=>{window.__setRangeApi({stateGaps:()=>Promise.resolve({data:{
  window:{from:'2026-08-25',to:'2026-08-26',h0:0,h1:23},rows:[],gap_slots:0,states_with_gap:0,
  excluded:['Transcarent Program Schedule'],unfilled:{hours:0,posts:0}}})});GW._init=0;window.__kickGaps()});
await p.waitForTimeout(300); r=await probe();
ok(/Every state is covered/.test(r.hero),'a real zero-gap answer still reads as covered');
ok(r.whenHidden&&r.tlHidden,'a clean window collapses instead of showing two empty cards');

// 5. a real result renders the cards
await p.evaluate(()=>{window.__setRangeApi({stateGaps:()=>Promise.resolve({data:{
  window:{from:'2026-08-25',to:'2026-08-26',h0:0,h1:23},gap_slots:2,states_with_gap:1,
  excluded:[],unfilled:{hours:0,posts:0},worst:['NC','2026-08-26',14,15,2],
  rows:[['NC',2,23.9,[['2026-08-26',14,'2026-08-26',15,2,23.9]]]]}})});GW._init=0;window.__kickGaps()});
await p.waitForTimeout(300); r=await probe();
ok(!r.whenHidden&&!r.tlHidden,'a real result shows both cards');
ok(/NC/.test(r.hero),'the hero names the exposed state');
ok(errs.length===0,`no pageerror (${JSON.stringify(errs)})`);
console.log(`\n${fail?'RESULT: FAIL':'RESULT: PASS'} (${pass} passed, ${fail} failed)`);
await b.close(); process.exit(fail?1:0);
