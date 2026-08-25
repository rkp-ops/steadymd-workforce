// Who's on used to render one row PER HOUR: a week was 168 rows and ~5,400px
// of scroll, with "51 states uncovered" repeated on nearly every line. It is
// now one row per DAY on a shared 24-hour axis.
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
   by_service_line:[],by_cred:[],top_clin:[],total_hours:0,n_shifts:0,n_clinicians:0},null,null,null,null,null,[]);});
// a full week, real row shape [date,hour,total,doc,np,pa,ma,gc,ms,gapStates,names]
const rows=[]; for(let d=25;d<=31;d++){const wknd=(d===29||d===30);
  for(let h=0;h<24;h++){const base=h===15&&d===25?32:((h>=13&&h<=22)?(wknd?4:12):(h<3?3:0));
    rows.push(['2026-08-'+d,h,base,Math.round(base*.28),Math.round(base*.62),
      base-Math.round(base*.28)-Math.round(base*.62),0,0,0,base?0:51,'AL, AK, AZ']);}}
await p.evaluate(R=>{window.__setRangeApi({whosOn:()=>Promise.resolve({data:{
  window:{from:'2026-08-25',to:'2026-08-31'},loaded:{min:'2026-05-31',max:'2026-08-31'},
  total_bodies:114,peak:32,calendars:[['Daytime Clinical Service Line',400]],rows:R}})});
  window.__kickWhosOn();},rows);
await p.waitForTimeout(450); await p.evaluate(()=>go('whoson')); await p.waitForTimeout(400);

const m=await p.evaluate(()=>{
  const days=[...document.querySelectorAll('#woBody .wgrid')].filter(g=>g.querySelector('.wdlab'));
  const strips=[...document.querySelectorAll('#woBody .wstrip')];
  const cellsOf=i=>[...strips[i].querySelectorAll('.wcell')];
  const h=el=>Math.round(el.getBoundingClientRect().height*10)/10;
  const filled=c=>[...c.querySelectorAll('i')].reduce((a,s)=>a+s.getBoundingClientRect().height,0);
  return {dayRows:days.length,
    labels:days.map(d=>d.querySelector('.wdlab').textContent),
    cellsPerRow:cellsOf(0).length,
    bodyH:Math.round(document.querySelector('#woBody').getBoundingClientRect().height),
    ruler:!!document.querySelector('#woBody .wruler'),
    peakFill:Math.round(filled(cellsOf(0)[15])), cellH:h(cellsOf(0)[15]),
    midFill:Math.round(filled(cellsOf(1)[15])),
    emptyFill:Math.round(filled(cellsOf(0)[5])),
    emptyIsRed:/var\(--bad\)|rgb\(220, 38, 38\)/.test(getComputedStyle(cellsOf(0)[5]).boxShadow||''),
    tip:cellsOf(0)[15].getAttribute('title'),
    stats:document.querySelector('#woStats').textContent,
    text:document.querySelector('#woBody').textContent};
});
ok(m.dayRows===7,`one row per day, not per hour (${m.dayRows} rows for a 168-hour window)`);
ok(m.cellsPerRow===24,`each day is a 24-hour strip (${m.cellsPerRow})`);
// bound is "fits in a laptop viewport without scrolling the page body", not a
// number picked to match today's render; the old layout was ~5,400px for a week
ok(m.bodyH<700,`a week fits on one screen (${m.bodyH}px, was ~5400)`);
ok(m.ruler,'the hour axis is labelled once, not per row');
ok(!/states uncovered/.test(m.text),'the per-hour "N states uncovered" wall is gone (Gaps owns that)');
ok(m.peakFill===m.cellH,`the busiest hour fills the cell (${m.peakFill}/${m.cellH}px)`);
ok(m.midFill>0&&m.midFill<m.peakFill,`a lighter hour is visibly shorter (${m.midFill}px vs ${m.peakFill}px)`);
ok(m.emptyFill===0,'an unstaffed hour draws no bar');
ok(!m.emptyIsRed,'an unstaffed hour is not painted as an alarm');
ok(/12 on/.test(m.tip)||/32 on/.test(m.tip),`hovering an hour gives the headcount and mix (${m.tip})`);
ok(/Hours with nobody on/.test(m.stats),'the tiles answer what this tab is for');
// days share one scale, so a thin weekend reads as thin
const wk=await p.evaluate(()=>{const s=[...document.querySelectorAll('#woBody .wstrip')];
  const f=i=>[...s[i].querySelectorAll('.wcell')][15].querySelectorAll('i');
  const sum=n=>[...n].reduce((a,x)=>a+x.getBoundingClientRect().height,0);
  return {wed:Math.round(sum(f(1))),sat:Math.round(sum(f(4)))}});
ok(wk.sat>0&&wk.sat<wk.wed,`days share one scale so a thin Saturday reads thin (Sat ${wk.sat}px vs Wed ${wk.wed}px)`);
ok(errs.length===0,`no pageerror (${JSON.stringify(errs)})`);
console.log(`\n${fail?'RESULT: FAIL':'RESULT: PASS'} (${pass} passed, ${fail} failed)`);
await b.close(); process.exit(fail?1:0);
