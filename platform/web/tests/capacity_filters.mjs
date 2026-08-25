// Shifts and Coverage must be filterable, and neither may render a failed read
// as a result. shift_summary/coverage_grid/demand_grid took only dates before.
import pw from '/opt/node22/lib/node_modules/playwright/index.js';
const {chromium}=pw; import {pathToFileURL} from 'url';
import {resolve,dirname} from 'path'; import {fileURLToPath} from 'url';
const PAGE=resolve(dirname(fileURLToPath(import.meta.url)),'../../../public/console-live.html');
let pass=0,fail=0; const ok=(c,m)=>{c?(pass++,console.log('PASS '+m)):(fail++,console.log('FAIL '+m))};
const b=await chromium.launch(); const p=await b.newPage({viewport:{width:1320,height:1000}});
const errs=[]; p.on('pageerror',e=>errs.push(e.message));
await p.goto(pathToFileURL(PAGE).href,{waitUntil:'domcontentloaded'}); await p.waitForTimeout(250);

// real shape from the live RPC
const SHIFTS={total_hours:1387.0,n_shifts:245,n_clinicians:84,
  range:{min:'2026-08-25',max:'2026-08-31'},loaded:{min:'2026-05-31',max:'2026-08-31'},
  excluded:['Transcarent Program Schedule','Thirty Madison - SRH','MA P2 Calls'],
  unfilled:{hours:0,posts:0},
  by_service_line:[{name:'Daytime Clinical Service Line',hours:812,shifts:120,people:40},
                   {name:'Wisp Schedule',hours:35,shifts:9,people:6}],
  by_cred:[{name:'NP',hours:1004,shifts:183,people:64},{name:'Doctor',hours:343.5,shifts:57,people:14}],
  by_hour:[[9,80,20],[10,90,22]], by_dow:[[1,200,40],[6,110,25]],
  top_clin:[{name:'A Clinician',cred:'NP',hours:40,shifts:5}],
  facets:{calendars:['Wisp Schedule','Daytime Clinical Service Line'],creds:['NP','Doctor']}};
const COV={weeks:5,bodies:134,excluded:['Transcarent Program Schedule'],
  grid:Array.from({length:7*24},(_,i)=>[Math.floor(i/24)+1,i%24,(i%24>=9&&i%24<=17)?6:1,0,9,1.2,0])};

await p.evaluate(S=>{document.getElementById('authgate')?.classList.add('hide');
  window.__init([['Amazon','UTI','TX','async_messaging',true,60,3,10,'2026-07-16']],null,[],S,
    null,null,null,null,null,[]);},SHIFTS);

let calls=[];
await p.evaluate(({S,C})=>{window.__calls=[];
  window.__setRangeApi({
    shifts:(a)=>{window.__calls.push(['shifts',a]);return Promise.resolve({data:S})},
    coverage:(a)=>{window.__calls.push(['coverage',a]);return Promise.resolve({data:C})},
    demand:(a)=>{window.__calls.push(['demand',a]);return Promise.resolve({data:{grid:[],arrivals:0,loaded:{min:'2026-05-31',max:'2026-07-16'}}})}});
},{S:SHIFTS,C:COV});

await p.evaluate(()=>go('shifts')); await p.waitForTimeout(300);
// filter controls exist at all
const ctl=await p.evaluate(()=>({cal:!!$('#shCalBtn'),cred:$$('#shCredF .qbtn').length,
  h0:$('#shH0')?$('#shH0').options.length:0,dow:$$('#shDow .qbtn').length,clear:!!$('#shClear')}));
ok(ctl.cal,'Shifts has a calendar picker');
ok(ctl.cred===6,`Shifts has all 6 credential buckets and no more (${ctl.cred})`);
ok(ctl.h0===24,`Shifts has an hour range control (${ctl.h0} options)`);
ok(ctl.dow===7,`Shifts has a day-of-week control (${ctl.dow})`);
ok(ctl.clear,'Shifts can clear its filters');

// a credential click must reach the server as p_cred
await p.evaluate(()=>{window.__calls=[];$$('#shCredF .qbtn').find(b=>b.dataset.c==='NP').click()});
await p.waitForTimeout(250);
calls=await p.evaluate(()=>window.__calls);
ok(calls.some(c=>c[0]==='shifts'&&Array.isArray(c[1].p_cred)&&c[1].p_cred.includes('NP')),
   `credential filter reaches the server (${JSON.stringify(calls.map(c=>c[1].p_cred))})`);
// hours + days too
await p.evaluate(()=>{window.__calls=[];const h=$('#shH1');h.value='17';h.dispatchEvent(new Event('change'));
  $$('#shDow .qbtn').find(b=>b.dataset.d==='6').click()});
await p.waitForTimeout(250);
calls=await p.evaluate(()=>window.__calls);
ok(calls.some(c=>c[1].p_hour1===17),'hour filter reaches the server');
ok(calls.some(c=>Array.isArray(c[1].p_dow)&&c[1].p_dow.includes(6)),'day filter reaches the server');
// "All" names what it excludes
const note=await p.evaluate(()=>({t:$('#shFNote').textContent,ttl:$('#shFNote').getAttribute('title')||''}));
ok(/siloed calendars excluded/.test(note.t),`"All" states its exclusions (${note.t})`);
ok(/Transcarent/.test(note.ttl),'the excluded calendars are named on hover');
// clear resets everything
await p.evaluate(()=>{window.__calls=[];$('#shClear').click()});
await p.waitForTimeout(250);
calls=await p.evaluate(()=>window.__calls);
ok(calls.some(c=>c[1].p_cred===null&&c[1].p_dow===null&&c[1].p_hour0===0&&c[1].p_hour1===23),
   'Clear filters resets every dimension');

// Coverage tab, same contract
await p.evaluate(()=>go('coverage')); await p.waitForTimeout(300);
const cctl=await p.evaluate(()=>({cal:!!$('#covCalBtn'),cred:$$('#covCredF .qbtn').length,dow:$$('#covDow .qbtn').length,
  note:$('#covNote').textContent}));
ok(cctl.cal&&cctl.cred===6&&cctl.dow===7,'Coverage has the same filter set');
ok(!/Central/.test(cctl.note),`Coverage no longer claims Central time (${cctl.note})`);
ok(/schedule/.test(cctl.note),'Coverage names the clock it actually uses');

// failure must not render as a result
await p.evaluate(()=>{window.__setRangeApi({shifts:()=>Promise.resolve({error:{message:'permission denied'}}),
  coverage:()=>Promise.resolve({error:{message:'boom'}}),demand:()=>Promise.resolve({data:{grid:[]}})});
  winFetch('shifts',null,null);winFetch('coverage',null,null)});
await p.waitForTimeout(300);
const f=await p.evaluate(()=>({sh:$('#shStats').textContent,cov:$('#covHeat').textContent}));
ok(/could not be read/i.test(f.sh)&&/permission denied/.test(f.sh),`Shifts states a failure (${f.sh.trim().slice(0,50)})`);
ok(/could not be read/i.test(f.cov)&&/boom/.test(f.cov),'Coverage states a failure');
ok(errs.length===0,`no pageerror (${JSON.stringify(errs)})`);
console.log(`\n${fail?'RESULT: FAIL':'RESULT: PASS'} (${pass} passed, ${fail} failed)`);
await b.close(); process.exit(fail?1:0);
