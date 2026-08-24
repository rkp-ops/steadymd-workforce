import pw from '/opt/node22/lib/node_modules/playwright/index.js';
const {chromium}=pw; import {pathToFileURL} from 'url';
import {resolve,dirname} from 'path';
import {fileURLToPath} from 'url';
const PAGE=resolve(dirname(fileURLToPath(import.meta.url)),'../../../public/console-live.html');
const errs=[]; const b=await chromium.launch(); const p=await b.newPage({viewport:{width:1320,height:1000}});
p.on('pageerror',e=>errs.push(e.message));
await p.goto(pathToFileURL(PAGE).href,{waitUntil:'domcontentloaded'});
await p.waitForTimeout(220);
await p.evaluate(()=>window.__init([['A','P','TX','async_messaging',true,60,3,10,'2026-07-16']],null,[],
  {loaded:{min:'2026-05-31',max:'2026-08-10'},range:{min:'2026-05-31',max:'2026-08-10'},
   by_service_line:[{name:'Daytime Clinical Service Line',hours:8,shifts:1},{name:'Wisp Schedule',hours:4,shifts:1}],
   by_cred:[],top_clin:[],total_hours:12,n_shifts:2,n_clinicians:2},null,null,null,null,null,[]));

const r=await p.evaluate(async()=>{
  const MOCK={window:{from:'2026-08-01',to:'2026-08-04',h0:0,h1:23},baseline:{from:'2026-06-19',to:'2026-07-16'},
    gap_slots:8,states_with_gap:2,unfilled:{hours:37,posts:12},
    excluded:['Transcarent Program Schedule','Thirty Madison - SRH','MA P2 Calls'],
    rows:[['MO',4,60,[['2026-08-02',2,'2026-08-02',5,4,60]]],
          ['WY',4,3.2,[['2026-08-01',9,'2026-08-01',10,2,1.6],['2026-08-03',22,'2026-08-03',23,2,1.6]]]],
    worst:['MO','2026-08-02',2,5,4]};
  window.__setRangeApi({stateGaps:(a)=>{window.__ga=a;return Promise.resolve({data:MOCK})}});
  window.__kickGaps(); await new Promise(r=>setTimeout(r,150)); go('gaps');
  const q=s=>(document.querySelector(s)||{}).textContent||'';
  const segs=[...document.querySelectorAll('#gapRows .gtseg')];
  return {args:window.__ga, hero:q('#gapHero'),
    rowCount:document.querySelectorAll('#gapRows .gtrow').length,
    labels:[...document.querySelectorAll('#gapRows .gtlab')].map(e=>e.textContent.trim()),
    segCount:segs.length, segCols:segs.map(e=>e.style.gridColumn),
    segTitle:segs[0]?.getAttribute('title')||'',
    trackCols:(document.querySelector('#gapRows .gttrack')||{}).style?.gridTemplateColumns||'',
    whenBars:document.querySelectorAll('#gapWhen .whenbar').length,
    whenFilled:[...document.querySelectorAll('#gapWhen .whenbar i')].length,
    whenTitles:[...document.querySelectorAll('#gapWhen .whenbar')].map(b=>b.getAttribute('title')),
    ticks:[...document.querySelectorAll('#gapTicks span')].map(e=>e.textContent),
    listRows:document.querySelectorAll('#gapRows .rk').length,
    scope:q('#gapScope'), scopeTitle:(document.querySelector('#gapScope b')||{}).title||'',
    rows:MOCK.rows};
});
// clean window collapses to one line
const clean=await p.evaluate(async()=>{
  window.__setRangeApi({stateGaps:()=>Promise.resolve({data:{window:{from:'2026-08-01',to:'2026-08-02',h0:0,h1:23},rows:[],unfilled:{hours:0,posts:0}}})});
  await (async()=>{const f=document.getElementById('gapFrom');f.value='2026-08-01';f.dispatchEvent(new Event('change'))})();
  await new Promise(r=>setTimeout(r,150));
  return {hero:(document.querySelector('#gapHero')||{}).textContent||'',
          rows:document.querySelectorAll('#gapRows .gtrow').length,
          heroH:Math.round((document.querySelector('#gapHero')||{}).getBoundingClientRect?.().height||0)};
});
const A=[],ok=(c,m)=>A.push((c?'PASS ':'FAIL ')+m);
ok(r.rowCount===2,`one row per uncovered state, not per hour (${r.rowCount})`);
ok(r.segCount===3,`contiguous hours merged into windows, not 8 loose cells (${r.segCount} segments for 8 gap-hours)`);
ok(r.trackCols.includes('repeat(96')||/(\d+px\s*){96}/.test(r.trackCols)||r.trackCols.split(' ').length===96,
   `track spans the whole window as 4 days x 24 hours (${r.trackCols.slice(0,40)})`);
ok(r.segCols[0]==='27 / span 4',`segment positioned by real time: Aug 2 is day 1, so 1*24+2 = col 27, span 4 (${r.segCols[0]})`);
ok(/MO uncovered/.test(r.segTitle)&&/02:00-06:00/.test(r.segTitle),`hover gives the exact window (${r.segTitle})`);
ok(r.labels[0].startsWith('MO'),`ranked by demand at risk, not raw hours (${JSON.stringify(r.labels)})`);
ok(r.whenBars===24,`when-profile spans all 24 hours of the day (${r.whenBars})`);
// only hours that actually have gaps get a bar; empty hours stay blank so a
// 1-gap hour never carries the same visual mass as a 6-gap hour
{ const sum=r.whenTitles.reduce((a,t)=>a+(+(String(t).match(/(\d+) uncovered state-hours/)||[0,0])[1]),0);
  const gaps=r.rows.reduce((a,x)=>a+x[1],0);
  ok(sum===gaps,`when-profile totals reconcile with the gap hours (${sum} vs ${gaps})`);
  ok(r.whenFilled<24&&r.whenFilled>0,`empty hours draw no bar (${r.whenFilled} of 24 hours have gaps)`); }
ok(JSON.stringify(r.ticks)===JSON.stringify(['Sat 1','Sun 2','Mon 3','Tue 4']),`day ticks on the axis (${JSON.stringify(r.ticks)})`);
ok(/Worst single window/.test(r.hero)&&/MO/.test(r.hero),'hero states the worst window outright');
// SILO: "All" must never quietly count Transcarent / 30M / MA P2 as coverage
ok(/All on-demand calendars/.test(r.scope)&&/3 siloed calendars excluded/.test(r.scope),
   `"All" names itself as on-demand only and counts the exclusions (${r.scope.trim()})`);
ok(/Transcarent Program Schedule/.test(r.scopeTitle)&&/MA P2 Calls/.test(r.scopeTitle),
   'excluded calendars are named on hover, not left implicit');
ok(/still unfilled/.test(r.hero),'posted-unfilled surfaced as a leading indicator');
ok(r.listRows===0,'no long call-out list remains');
ok(/Every state is covered/.test(clean.hero)&&clean.rows===0,`clean window collapses to one line (${clean.hero.slice(0,50)})`);
ok(clean.heroH<80,`empty state is one line, not a full-height card (${clean.heroH}px)`);
ok(errs.length===0,`no pageerror (${JSON.stringify(errs)})`);
console.log(A.join('\n'));console.log('\n'+(A.some(x=>x.startsWith('FAIL'))?'RESULT: FAIL':'RESULT: PASS'));
await b.close();process.exit(A.some(x=>x.startsWith('FAIL'))?1:0);
