// Coverage console (Gaps / Who's on / State coverage) - client-side engine test.
// Boots the console with mock __init, injects a coverage_feed fixture through
// RANGE_API, and drives the three tabs: render, 12-hour time, the shared
// date/hour/calendar control, and the call-out override layer.
import pw from '/opt/node22/lib/node_modules/playwright/index.js';
const {chromium}=pw; import {pathToFileURL} from 'url';
import {resolve,dirname} from 'path'; import {fileURLToPath} from 'url';
const PAGE=resolve(dirname(fileURLToPath(import.meta.url)),'../../../public/console-live.html');

const FEED={
  window:{from:'2026-08-25',to:'2026-08-26'},
  loaded:{min:'2026-08-25',max:'2026-08-31'},
  baseline:{from:'2026-07-29',to:'2026-08-25'},
  calendars:[['Daytime Clinical Service Line','CSL','Daytime Clinical',3],
             ['Weight Management Service Line','WSL','Weight Management',1],
             ['Wisp Schedule','Wisp','Wisp',1],
             ['EZ Health','EZH','EZ Health',1],
             ['HealthOme Program Schedule','HmL','HealthOme',1]],
  roster:[
    ['Sarah Stone','Doctor','CSL','2026-08-25T09:00','2026-08-25T17:00','NC,TX,CA,FL,NY,GA'],
    ['Jane Doe','NP','CSL','2026-08-25T17:00','2026-08-26T01:00','TX,CA,FL'],
    ['Owen Knight','NP','CSL','2026-08-24T22:00','2026-08-25T06:00','TX'],
    ['Bob Rivera','NP','CSL','2026-08-26T09:00','2026-08-26T17:00','NC,GA,TX'],
    ['Amy Ho','Doctor','WSL','2026-08-25T08:00','2026-08-25T13:30','IA,IL'],
    ['Zed Ez','NP','EZH','2026-08-25T17:00','2026-08-26T01:00','NC']   // covers NC evening, but EZH is off by default
  ],
  // [state, hour, async_per_day, sync_per_day]
  demand:(()=>{const d=[];
    for(let h=10;h<=21;h++)d.push(['NC',h,3.2,h===14||h===18?1.1:0]);   // NC evening uncovered (only TX/CA/FL on after 5pm)
    for(let h=9;h<=23;h++)d.push(['TX',h,5.0,h%4===0?0.6:0]);
    for(let h=9;h<=17;h++)d.push(['IA',h,2.0,0]);
    for(let h=9;h<=17;h++)d.push(['IL',h,1.5,0]);
    return d})()
};

const errs=[]; const b=await chromium.launch(); const p=await b.newPage({viewport:{width:1340,height:1400}});
p.on('pageerror',e=>errs.push('PAGEERR: '+e.message));
// ignore sandbox network noise (the Supabase CDN <script> can't load offline)
p.on('console',m=>{if(m.type()==='error'&&!/ERR_(CONNECTION|NETWORK|NAME_NOT)|Failed to load resource/.test(m.text()))errs.push('CONSOLE: '+m.text())});
await p.goto(pathToFileURL(PAGE).href,{waitUntil:'domcontentloaded'});
await p.waitForTimeout(200);
await p.evaluate(()=>{
  const R=o=>Object.assign({em:[],al:[],mo:[],as:[],pa:[],pr:['P'],sh:0,inc:0,needs:[],tier:'seat',st:'active',la:'2026-07-16',ls:['TX'],npi:'1'},o);
  window.__init([],null,[R({rid:'1',n:'A B',c:'MD',ct:5})],
   {loaded:{min:'2026-08-25',max:'2026-08-31'},range:{min:'2026-08-25',max:'2026-08-31'},
    by_service_line:[{name:'CSL',hours:8,shifts:1}],by_cred:[{name:'NP',hours:8,shifts:1}],top_clin:[],total_hours:8,n_shifts:1,n_clinicians:1},
   null,null,null,null,null,[]);
});
// inject the coverage feed and kick the engine; hide the offline auth gate for screenshots
await p.evaluate((FEED)=>{ const g=document.getElementById('authgate'); if(g)g.classList.add('hide');
  window.__setRangeApi({coverageFeed:()=>Promise.resolve({data:FEED})}); window.__kickCoverage(); }, FEED);
await p.waitForTimeout(300);

const A=[],ok=(c,m)=>A.push((c?'PASS ':'FAIL ')+m);

// ---- Gaps ----
await p.evaluate(()=>go('gaps')); await p.waitForTimeout(120);
const gaps=await p.evaluate(()=>{
  const grp=[...document.querySelectorAll('#cvGapBody tr.grp')].map(t=>t.textContent.trim());
  const states=[...document.querySelectorAll('#cvGapBody tr.sum b')].map(b=>b.textContent);
  const times=[...document.querySelectorAll('#cvGapBody tr.sum td')].map(td=>td.textContent).join(' ');
  return {grp,states,times};
});
ok(gaps.grp.length>0 && gaps.states.includes('NC'), 'gaps: NC evening gap surfaces, grouped by date ('+gaps.grp.length+' date groups, '+gaps.states.length+' gaps)');
ok(/AM|PM/.test(gaps.times), 'gaps: times render 12-hour');
await p.screenshot({path:resolve(dirname(fileURLToPath(import.meta.url)),'cov_gaps.png')});

// expand the NC gap -> who is on (none licensed in NC)
await p.evaluate(()=>{const r=[...document.querySelectorAll('#cvGapBody tr.sum')].find(t=>t.querySelector('b')&&t.querySelector('b').textContent==='NC');if(r)r.click();});
await p.waitForTimeout(100);
const gapDet=await p.evaluate(()=>{const d=document.querySelector('#cvGapBody tr.det');return d?d.textContent:''});
ok(/none licensed in NC/.test(gapDet)||/staffing gap/.test(gapDet),'gaps: expand shows who is on (none licensed in NC)');

// ---- Who's on ----
await p.evaluate(()=>go('whoson')); await p.waitForTimeout(120);
const who=await p.evaluate(()=>{
  const rows=[...document.querySelectorAll('#cvWoBody tr.sum')].map(t=>t.querySelector('b')?t.querySelector('b').textContent:'');
  const ctrl=document.querySelector('#cvWoCtrl');
  const presets=[...ctrl.querySelectorAll('[data-cvpreset]')].map(b=>b.textContent);
  const cals=[...ctrl.querySelectorAll('[data-cvcal]')].map(c=>c.parentElement.textContent.trim());
  const hasHours=!!ctrl.querySelector('[data-cvh0]');
  const more=!!ctrl.querySelector('[data-cvmore]');
  return {rows,presets,cals,hasHours,more,desc:document.querySelector('#cvWoDesc').textContent};
});
ok(who.rows.length>=3,'whoson: roster table renders shift blocks ('+who.rows.length+')');
ok(who.presets.join(',')==='Today,Tomorrow,This week,This weekend','whoson: presets are Today/Tomorrow/This week/This weekend ('+who.presets.join(',')+')');
ok(who.hasHours && who.cals.join(',')==='CSL,WSL,Wisp' && who.more,'whoson: calendars standardized to abbrevs; EZ Health + HealthOme hidden behind "+ more" ('+who.cals.join(', ')+')');
await p.screenshot({path:resolve(dirname(fileURLToPath(import.meta.url)),'cov_whoson.png')});

// ---- call-out override ----
const before=await p.evaluate(()=>document.querySelector('#cvGapDesc')?1:1);
await p.evaluate(()=>{const btn=document.querySelector('#cvWoBody tr.sum .outbtn');if(btn)btn.click();});
await p.waitForTimeout(150);
const co=await p.evaluate(()=>{
  const ed=document.querySelector('#cvWoEdit');
  return {on:ed.classList.contains('on'),lead:(ed.querySelector('.lead')||{}).textContent||'',
    chips:ed.querySelectorAll('.outchip').length,
    outRow:document.querySelectorAll('#cvWoBody tr.sum.out').length,
    calledOutPill:/called out/.test(document.querySelector('#cvWoBody').textContent)};
});
ok(co.on && co.chips===1 && /Called out \(1\)/.test(co.lead),'call-out: banner shows the called-out clinician ('+co.lead+', '+co.chips+' chip)');
ok(co.outRow===1 && co.calledOutPill,'call-out: the row is highlighted (strikethrough + called-out pill)');
await p.screenshot({path:resolve(dirname(fileURLToPath(import.meta.url)),'cov_callout.png')});
// undo via chip
await p.evaluate(()=>{const c=document.querySelector('#cvWoEdit .outchip');if(c)c.click();});
await p.waitForTimeout(120);
const undone=await p.evaluate(()=>document.querySelector('#cvWoEdit').classList.contains('on'));
ok(!undone,'call-out: undo via chip clears it');

// ---- calendars: EZ Health / HealthOme hidden + off by default; checkable on demand ----
await p.evaluate(()=>go('gaps')); await p.waitForTimeout(100);
const ncBefore=await p.evaluate(()=>[...document.querySelectorAll('#cvGapBody tr.sum b')].map(b=>b.textContent).filter(s=>s==='NC').length);
await p.evaluate(()=>{const m=document.querySelector('#cvGapCtrl [data-cvmore]');if(m)m.click();});   // reveal hidden calendars
await p.waitForTimeout(80);
const ezhVisible=await p.evaluate(()=>!!document.querySelector('#cvGapCtrl [data-cvcal="EZH"]'));
await p.evaluate(()=>{const c=document.querySelector('#cvGapCtrl [data-cvcal="EZH"]');if(c&&!c.checked){c.checked=true;c.dispatchEvent(new Event('change',{bubbles:true}))}});
await p.waitForTimeout(120);
const ncAfter=await p.evaluate(()=>[...document.querySelectorAll('#cvGapBody tr.sum b')].map(b=>b.textContent).filter(s=>s==='NC').length);
ok(ncBefore>=1 && !ezhVisible===false && ncAfter<ncBefore,'calendars: EZ Health hidden + off by default (NC gaps '+ncBefore+'); reveal + check it and its NC coverage counts ('+ncAfter+')');
await p.evaluate(()=>{const c=document.querySelector('#cvGapCtrl [data-cvcal="EZH"]');if(c&&c.checked){c.checked=false;c.dispatchEvent(new Event('change',{bubbles:true}))}});   // restore default
await p.waitForTimeout(100);

// ---- State coverage: hour scoping ----
await p.evaluate(()=>go('states')); await p.waitForTimeout(120);
const ncAll=await p.evaluate(()=>{const r=[...document.querySelectorAll('#cvStBody tr.sum')].find(t=>t.querySelector('b')&&t.querySelector('b').textContent==='NC');return r?+[...r.querySelectorAll('td.r')][0].textContent:null});
// narrow hours to 6 PM (18) - 10 PM (22): NC evening only
await p.evaluate(()=>{const s0=document.querySelector('#cvStCtrl [data-cvh0]');s0.value='18';s0.dispatchEvent(new Event('change',{bubbles:true}));});
await p.waitForTimeout(80);
await p.evaluate(()=>{const s1=document.querySelector('#cvStCtrl [data-cvh1]');s1.value='22';s1.dispatchEvent(new Event('change',{bubbles:true}));});
await p.waitForTimeout(120);
const ncEve=await p.evaluate(()=>{const r=[...document.querySelectorAll('#cvStBody tr.sum')].find(t=>t.querySelector('b')&&t.querySelector('b').textContent==='NC');return r?+[...r.querySelectorAll('td.r')][0].textContent:null});
ok(ncAll!=null && ncEve!=null && ncEve<ncAll,'states: async demand scopes to selected hours (NC all-day '+ncAll+' -> 6-10 PM '+ncEve+')');
// pivot has a 12 AM row
const pivHas12AM=await p.evaluate(()=>/12 AM/.test(document.querySelector('#cvPivTbl').textContent));
ok(pivHas12AM,'states: bodies-by-hour pivot includes 12 AM (midnight)');
await p.screenshot({path:resolve(dirname(fileURLToPath(import.meta.url)),'cov_states.png')});

// ---- fail-state: a failed feed read must NEVER render as an all-clear ----
await p.evaluate(()=>{ window.__setRangeApi({coverageFeed:()=>Promise.resolve({error:{message:'boom'}})}); return cvFetch('2026-08-25','2026-08-26'); });
await p.waitForTimeout(150);
const fail=await p.evaluate(()=>({gap:document.querySelector('#cvGapBody').textContent,
  clear:/every state is covered|no gaps/i.test(document.querySelector('#cvGapBody').textContent)}));
ok(/could not be read/i.test(fail.gap) && !fail.clear,'fail-state: a failed read shows an error, never a false all-clear');
// restore good feed for the remaining checks
await p.evaluate((FEED)=>{ window.__setRangeApi({coverageFeed:()=>Promise.resolve({data:FEED})}); return cvFetch('2026-08-25','2026-08-26'); }, FEED);
await p.waitForTimeout(150);

// ---- global: no 24-hour time anywhere in the three tabs, no errors ----
const mil=await p.evaluate(()=>{['gaps','whoson','states'].forEach(t=>{const s=document.querySelector('[data-tab="'+t+'"]');if(s)s.style.display='block'});
  const txt=['gaps','whoson','states'].map(t=>document.querySelector('[data-tab="'+t+'"]').innerText).join(' ');
  return (txt.match(/\b(1[3-9]|2[0-3]):[0-5]\d\b/g)||[]);});
ok(mil.length===0,'no 24-hour/military time in the coverage tabs ('+mil.slice(0,3).join(',')+')');
ok(errs.length===0,'no pageerror/console error ('+JSON.stringify(errs.slice(0,2))+')');

console.log(A.join('\n'));console.log('\n'+(A.some(x=>x.startsWith('FAIL'))?'RESULT: FAIL':'RESULT: PASS'));
await b.close();process.exit(A.some(x=>x.startsWith('FAIL'))?1:0);
