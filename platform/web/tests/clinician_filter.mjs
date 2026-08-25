// "no filters or ability to look specifically at what I want to instead of
// EVERYTHING across calendars, times, days, and clinicians" - clinicians was
// the one dimension still missing. 215 names cannot be a chip wall.
import pw from '/opt/node22/lib/node_modules/playwright/index.js';
const {chromium}=pw; import {pathToFileURL} from 'url';
import {resolve,dirname} from 'path'; import {fileURLToPath} from 'url';
const PAGE=resolve(dirname(fileURLToPath(import.meta.url)),'../../../public/console-live.html');
let pass=0,fail=0; const ok=(c,m)=>{c?(pass++,console.log('PASS '+m)):(fail++,console.log('FAIL '+m))};
const NAMES=['Abigail Burns','Bo Chen','Casey Lin','Dana Ruiz','Eli Novak','Fay Osei','Gus Patel',
 'Hana Kim','Ivy Sosa','Jon Reyes','Kai Mensah','Lena Ortiz','Mo Diallo','Nia Frank','Omar Haddad'];
const clinicians=[];
for(let i=0;i<215;i++){const n=NAMES[i%NAMES.length]+' '+(i+1);
  clinicians.push(['user'+i+'@example.test',n]);}
clinicians.sort((a,b)=>a[1].localeCompare(b[1]));
const S={total_hours:1387,n_shifts:245,n_clinicians:215,range:{min:'2026-08-25',max:'2026-08-31'},
  loaded:{min:'2026-05-31',max:'2026-08-31'},excluded:[],unfilled:{hours:0,posts:0},
  by_service_line:[{name:'Daytime Clinical Service Line',hours:812,shifts:120,people:40}],
  by_cred:[{name:'NP',hours:1004,shifts:183,people:64}],by_hour:[],by_dow:[],
  top_clin:[{name:'Abigail Burns 1',cred:'NP',hours:45,shifts:6}],
  facets:{calendars:['Daytime Clinical Service Line'],creds:['NP'],clinicians}};
const b=await chromium.launch(); const p=await b.newPage({viewport:{width:1320,height:900}});
const errs=[]; p.on('pageerror',e=>errs.push(e.message));
await p.goto(pathToFileURL(PAGE).href,{waitUntil:'domcontentloaded'}); await p.waitForTimeout(250);
await p.evaluate(x=>{document.getElementById('authgate')?.classList.add('hide');
  window.__init([['A','U','TX','async_messaging',true,60,3,10,'2026-07-16']],null,[],x,null,null,null,null,null,[]);},S);
await p.evaluate(x=>{window.__calls=[];window.__setRangeApi({
  shifts:(a)=>{window.__calls.push(a);return Promise.resolve({data:x})},
  coverage:(a)=>{window.__calls.push(a);return Promise.resolve({data:{grid:[],weeks:0}})},
  demand:()=>Promise.resolve({data:{grid:[]}})});},S);
await p.evaluate(()=>go('shifts')); await p.waitForTimeout(350);

ok(await p.evaluate(()=>!!$('#shClinBtn')),'Shifts has a clinician picker');
await p.evaluate(()=>$('#shClinBtn').click()); await p.waitForTimeout(150);
const shape=await p.evaluate(()=>({search:!!$('#shClinPop [data-q]'),
  rendered:$$('#shClinPop [data-sv]').length, more:$('#shClinPop .popmore-slot').textContent}));
ok(shape.search,'the picker has a search field, not 215 chips');
ok(shape.rendered<=60,`only a readable page of names is rendered (${shape.rendered} of 215)`);
ok(/more not shown/.test(shape.more),`what is hidden is stated, never silently truncated (${shape.more.trim()})`);
// typing narrows
await p.evaluate(()=>{const q=$('#shClinPop [data-q]');q.value='Ivy';q.dispatchEvent(new Event('input'))});
await p.waitForTimeout(120);
const nar=await p.evaluate(()=>$$('#shClinPop [data-sv]').map(b=>b.textContent));
ok(nar.length>0&&nar.every(n=>/Ivy/.test(n)),`typing narrows the list (${nar.length} matches for "Ivy")`);
// selecting reaches the server as p_clinician
await p.evaluate(()=>{window.__calls=[];$$('#shClinPop [data-sv]')[0].click()});
await p.waitForTimeout(250);
const calls=await p.evaluate(()=>window.__calls);
ok(calls.some(c=>Array.isArray(c.p_clinician)&&c.p_clinician.length===1),
   `picking a clinician reaches the server (${JSON.stringify(calls.map(c=>c.p_clinician))})`);
ok(await p.evaluate(()=>/@example\.test$/.test([...CAPF.shifts.clin][0]||'')),
   'selection is by email, so a rename cannot silently drop the filter');
const lbl=await p.evaluate(()=>$('#shClinLbl').textContent);
ok(/Ivy/.test(lbl),`the button names who is selected (${lbl})`);
ok(/1 clinician/.test(await p.evaluate(()=>$('#shFNote').textContent)),'the filter note says a clinician is applied');
// picker must not collapse to the one selected person
await p.evaluate(()=>{$('#shClinBtn').click()}); await p.waitForTimeout(150);
ok(await p.evaluate(()=>CLINROSTER.length===215),'the roster offered stays whole after a pick');
// clear resets it
await p.evaluate(()=>{window.__calls=[];$('#shClear').click()}); await p.waitForTimeout(250);
ok(await p.evaluate(()=>window.__calls.some(c=>c.p_clinician===null)),'Clear filters drops the clinician pick');
ok(await p.evaluate(()=>$('#shClinLbl').textContent==='All'),'and resets its label');
// Coverage has it too
await p.evaluate(()=>go('coverage')); await p.waitForTimeout(300);
ok(await p.evaluate(()=>!!$('#covClinBtn')),'Coverage has the same clinician picker');
// demand_grid takes no p_clinician - sending one would fail the call
await p.evaluate(()=>{window.__dcalls=[];window.__setRangeApi({
  shifts:()=>Promise.resolve({data:{}}),coverage:()=>Promise.resolve({data:{grid:[],weeks:0}}),
  demand:(a)=>{window.__dcalls.push(a);return Promise.resolve({data:{grid:[]}})}});
  CAPF.coverage.clin.add('user1@example.test');winFetch('forecast',null,null)});
await p.waitForTimeout(250);
const dc=await p.evaluate(()=>window.__dcalls);
ok(dc.length&&!('p_clinician' in dc[0]),
   `demand is never sent a clinician filter (${JSON.stringify(Object.keys(dc[0]||{}))})`);
ok(dc.length&&dc[0].p_hour0===0,'demand still receives the shared window and hour filters');
ok(errs.length===0,`no pageerror (${JSON.stringify(errs)})`);
console.log(`\n${fail?'RESULT: FAIL':'RESULT: PASS'} (${pass} passed, ${fail} failed)`);
await b.close(); process.exit(fail?1:0);
