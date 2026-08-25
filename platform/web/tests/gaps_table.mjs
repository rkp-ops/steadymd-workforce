// The gaps tab must be readable WITHOUT hovering: state, day of week, start,
// end, length, and who is on shift all present as text in every row. The chart
// it replaced compressed 168 hour-columns into ~1000px, so a 1-hour gap was a
// 6px splotch and every one of those facts needed a hover to extract.
import pw from '/opt/node22/lib/node_modules/playwright/index.js';
const {chromium}=pw; import {pathToFileURL} from 'url';
import {resolve,dirname} from 'path'; import {fileURLToPath} from 'url';
import fs from 'fs';
const PAGE=resolve(dirname(fileURLToPath(import.meta.url)),'../../../public/console-live.html');
let pass=0,fail=0; const ok=(c,m)=>{c?(pass++,console.log('PASS '+m)):(fail++,console.log('FAIL '+m))};
// real payload shape from the deployed RPC
const REAL={window:{h0:0,h1:23,to:'2026-08-31',from:'2026-08-25'},
 by_hour:[[0,8],[1,8],[23,11],[14,4]],
 excluded:[],unfilled:{hours:0,posts:0},gap_slots:66,slots_total:8568,states_with_gap:16,
 windows:[
  ['NC','2026-08-30',14,'2026-08-30',20,6,28.6,2,[['Doctor',1],['NP',1]]],
  ['MA','2026-08-30',14,'2026-08-30',23,9,24.0,3,[['NP',2],['Doctor',1]]],
  ['MA','2026-08-28',23,'2026-08-29',2,3,3.0,1,[['Doctor',1]]],   // crosses midnight
  ['HI','2026-08-31',5,'2026-08-31',6,1,0.0,0,[]]]};              // nobody on at all
const b=await chromium.launch(); const p=await b.newPage({viewport:{width:1320,height:1000}});
const errs=[]; p.on('pageerror',e=>errs.push(e.message));
await p.goto(pathToFileURL(PAGE).href,{waitUntil:'domcontentloaded'}); await p.waitForTimeout(250);
await p.evaluate(()=>{document.getElementById('authgate')?.classList.add('hide');
  window.__init([['A','U','TX','async_messaging',true,60,3,10,'2026-07-16']],null,[],
  {loaded:{min:'2026-05-31',max:'2026-08-31'},range:{min:'2026-05-31',max:'2026-08-31'},
   by_service_line:[{name:'Daytime Clinical Service Line',hours:8,shifts:1}],by_cred:[],top_clin:[],
   total_hours:8,n_shifts:1,n_clinicians:1},null,null,null,null,null,[]);});
await p.evaluate(R=>{window.__setRangeApi({stateGaps:()=>Promise.resolve({data:R})});window.__kickGaps();},REAL);
await p.waitForTimeout(400); await p.evaluate(()=>go('gaps')); await p.waitForTimeout(300);

const cells=await p.evaluate(()=>[...document.querySelectorAll('#gapTblBody tr')]
  .map(tr=>[...tr.children].map(td=>td.textContent.trim())));
ok(cells.length===4,`one row per gap window (${cells.length})`);
// EVERY fact readable without hover, on the worst row
const r0=cells[0];
ok(r0[0]==='NC',`state is text (${r0[0]})`);
ok(/^Sun /.test(r0[1]),`day names the DAY OF WEEK, no column counting (${r0[1]})`);
ok(r0[2]==='14:00',`start time is text (${r0[2]})`);
ok(r0[3]==='20:00',`end time is text (${r0[3]})`);
ok(r0[4]==='6h',`length is text (${r0[4]})`);
ok(/Doctor/.test(r0[7])&&/NP/.test(r0[7]),`who is on shift and their credentials are text (${r0[7]})`);
ok(/none licensed in NC/.test(r0[7]),'it says plainly that none of them cover the state');
// no hover anywhere in the table
const titles=await p.evaluate(()=>[...document.querySelectorAll('#gapTblBody [title]')].length);
ok(titles===0,`nothing in the table is hidden behind a tooltip (${titles} title attrs)`);
// a window crossing midnight must name the end DAY, not silently roll over
ok(/Sat 29/.test(cells[2][3]),`a gap crossing midnight names the end day (${cells[2][3]})`);
// nobody-on-shift is called out, not shown as a blank
ok(/nobody on shift/i.test(cells[3][7]),`an unstaffed gap says so (${cells[3][7]})`);
// sorting
await p.evaluate(()=>[...document.querySelectorAll('#gapTbl th')].find(t=>t.dataset.sort==='beg').click());
await p.waitForTimeout(150);
const byStart=await p.evaluate(()=>[...document.querySelectorAll('#gapTblBody tr')].map(tr=>tr.children[2].textContent.trim()));
ok(byStart[0]<=byStart[byStart.length-1],`clicking a column sorts by it (${JSON.stringify(byStart)})`);
await p.evaluate(()=>[...document.querySelectorAll('#gapTbl th')].find(t=>t.dataset.sort==='st').click());
await p.waitForTimeout(150);
const byState=await p.evaluate(()=>[...document.querySelectorAll('#gapTblBody tr')].map(tr=>tr.children[0].textContent.trim()));
ok(JSON.stringify(byState)===JSON.stringify([...byState].sort()),`state sorts alphabetically (${JSON.stringify(byState)})`);
// hero states the worst gap in words
const hero=await p.evaluate(()=>$('#gapHero').textContent);
ok(/Worst gap/.test(hero)&&/NC/.test(hero)&&/14:00/.test(hero)&&/20:00/.test(hero),
   `hero names the worst gap with its times (${hero.replace(/\s+/g,' ').trim().slice(0,90)})`);
ok(/most gaps start around/.test(hero),'when gaps cluster is said in words, not drawn as a chart');
// the old chart is gone
const gone=await p.evaluate(()=>({when:!!document.querySelector('#gapWhen'),seg:!!document.querySelector('.gtseg')}));
ok(!gone.when&&!gone.seg,'the unreadable bar/timeline chart is gone');
ok(errs.length===0,`no pageerror (${JSON.stringify(errs)})`);
console.log(`\n${fail?'RESULT: FAIL':'RESULT: PASS'} (${pass} passed, ${fail} failed)`);
await b.close(); process.exit(fail?1:0);
