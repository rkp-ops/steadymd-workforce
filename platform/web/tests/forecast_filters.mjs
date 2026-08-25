// Forecast had no controls but was changed to use capArgs('coverage'), so it
// silently inherited whatever the Coverage tab was filtered to with nothing on
// screen saying so. It now owns its own filter state and shows it.
import pw from '/opt/node22/lib/node_modules/playwright/index.js';
const {chromium}=pw; import {pathToFileURL} from 'url';
import {resolve,dirname} from 'path'; import {fileURLToPath} from 'url';
const PAGE=resolve(dirname(fileURLToPath(import.meta.url)),'../../../public/console-live.html');
let pass=0,fail=0; const ok=(c,m)=>{c?(pass++,console.log('PASS '+m)):(fail++,console.log('FAIL '+m))};
const b=await chromium.launch(); const p=await b.newPage({viewport:{width:1320,height:900}});
const errs=[]; p.on('pageerror',e=>errs.push(e.message));
await p.goto(pathToFileURL(PAGE).href,{waitUntil:'domcontentloaded'}); await p.waitForTimeout(250);
await p.evaluate(()=>{document.getElementById('authgate')?.classList.add('hide');
  window.__init([['A','U','TX','async_messaging',true,60,3,10,'2026-07-16']],null,[],
  {loaded:{min:'2026-05-31',max:'2026-08-31'},range:{min:'2026-05-31',max:'2026-08-31'},
   by_service_line:[{name:'Daytime Clinical Service Line',hours:8,shifts:1}],by_cred:[],top_clin:[],
   total_hours:8,n_shifts:1,n_clinicians:1,
   facets:{calendars:['Daytime Clinical Service Line'],creds:['NP'],
           clinicians:[['a@x.test','Abigail Burns'],['b@x.test','Bo Chen']]}},
  null,null,null,null,null,[]);});
await p.evaluate(()=>{window.__d=[];window.__c=[];window.__setRangeApi({
  shifts:()=>Promise.resolve({data:{}}),
  coverage:(a)=>{window.__c.push(a);return Promise.resolve({data:{grid:[],weeks:0}})},
  demand:(a)=>{window.__d.push(a);return Promise.resolve({data:{grid:[],arrivals:0,
    loaded:{min:'2026-05-31',max:'2026-07-16'}}})}});});
await p.evaluate(()=>go('shifts')); await p.waitForTimeout(250);
await p.evaluate(()=>go('forecast')); await p.waitForTimeout(350);

ok(await p.evaluate(()=>!!$('#fcFilters')),'Forecast has its own filter bar');
ok(await p.evaluate(()=>$$('#fcCredF .qbtn').length===6&&$$('#fcDow .qbtn').length===7),
   'with the same credential and day controls');
ok(await p.evaluate(()=>!!$('#fcClinBtn')&&!!$('#fcCalBtn')),'and its own calendar + clinician pickers');
// the defect: Coverage filters must NOT leak into Forecast
await p.evaluate(()=>{CAPF.coverage.cred.add('Doctor');CAPF.coverage.h0=9;
  window.__d=[];window.__c=[];winFetch('forecast',null,null)});
await p.waitForTimeout(250);
const leak=await p.evaluate(()=>({d:window.__d[0],c:window.__c[0]}));
ok(leak.c&&leak.c.p_cred===null&&leak.c.p_hour0===0,
   `Coverage's filters do not leak into Forecast (${JSON.stringify([leak.c.p_cred,leak.c.p_hour0])})`);
// its own filters DO apply, to both sides
await p.evaluate(()=>{window.__d=[];window.__c=[];
  $$('#fcCredF .qbtn').find(b=>b.dataset.c==='NP').click()});
await p.waitForTimeout(250);
const own=await p.evaluate(()=>({d:window.__d[0],c:window.__c[0]}));
ok(own.c&&Array.isArray(own.c.p_cred)&&own.c.p_cred.includes('NP'),'its own credential filter reaches coverage');
ok(own.d&&Array.isArray(own.d.p_cred)&&own.d.p_cred.includes('NP'),'and the same filter moves demand with it');
ok(own.d&&!('p_clinician' in own.d),'demand is still never sent a clinician filter');
// empty state distinguishes "no demand" from "past the demand horizon"
const msg=await p.evaluate(()=>$('#fcHeat').textContent);
ok(/2026-07-16/.test(msg),`the empty state names the demand horizon (${msg.trim().slice(0,80)})`);
ok(!/Central time/.test(await p.evaluate(()=>$('#fcNote').textContent)),'Forecast no longer claims Central time');
ok(errs.length===0,`no pageerror (${JSON.stringify(errs)})`);
console.log(`\n${fail?'RESULT: FAIL':'RESULT: PASS'} (${pass} passed, ${fail} failed)`);
await b.close(); process.exit(fail?1:0);
