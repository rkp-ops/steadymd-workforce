import pw from '/opt/node22/lib/node_modules/playwright/index.js';
const {chromium}=pw; import {pathToFileURL} from 'url';
import {resolve,dirname} from 'path';
import {fileURLToPath} from 'url';
const PAGE=resolve(dirname(fileURLToPath(import.meta.url)),'../../../public/console-live.html');
const errs=[]; const b=await chromium.launch(); const p=await b.newPage({viewport:{width:1320,height:900}});
p.on('pageerror',e=>errs.push(e.message));
await p.goto(pathToFileURL(PAGE).href,{waitUntil:'domcontentloaded'});
await p.waitForTimeout(220);
await p.evaluate(()=>{
  const R=o=>Object.assign({em:[],al:[],mo:[],as:[],pa:[],pr:['P'],sh:0,inc:0,needs:[],tier:'seat',st:'active',la:'2026-07-16',ls:['TX'],npi:'1'},o);
  const rows=[];for(let i=0;i<300;i++)rows.push(['Amazon Clinic','UTI',i%2?'TX':'CA',i%3?'async_messaging':'video_chat',i%7!==0,60+i,3,10,'2026-07-16']);
  window.__init(rows,null,[R({rid:'1',n:'A B',c:'MD',ct:5}),R({rid:'2',n:'C D',c:'NP',ct:3})],
   {loaded:{min:'2026-05-31',max:'2026-08-10'},range:{min:'2026-05-31',max:'2026-08-10'},
    by_service_line:[{name:'CSL',hours:8,shifts:1}],by_cred:[{name:'NP',hours:8,shifts:1}],top_clin:[],total_hours:8,n_shifts:1,n_clinicians:1},
   null,null,null,null,null,[{partner_key:'amazon',label:'Amazon Clinic',panel:'on_demand',sync_min:30,async_min:240,floor:.95,basis:'',note:''}]);
});
const tabs=['overview','scoreboard','performance','scheduled','review','consults','whoson','gaps','states','shifts','coverage','forecast','incentives','clinicians','productivity','playbook'];
const out={};
for(const t of tabs){ await p.evaluate(x=>go(x),t); await p.waitForTimeout(70);
  out[t]=await p.evaluate(x=>{const s=document.querySelector('[data-tab="'+x+'"]');
    return s?{on:s.classList.contains('on'),html:s.innerHTML.length}:null},t); }
// core invariants that Phase 1/2 established
const inv=await p.evaluate(()=>{
  const cs=n=>getComputedStyle(n);
  const shadows=[...document.querySelectorAll('*')].filter(n=>cs(n).boxShadow!=='none').length;
  const radii=new Set([...document.querySelectorAll('*')].map(n=>cs(n).borderRadius).filter(v=>v&&v!=='0px'));
  const numBad=[...document.querySelectorAll('td.r,td.num')].filter(n=>cs(n).textAlign!=='right').length;
  const clipped=[...document.querySelectorAll('table.fx td.r,table.fx td.num')].filter(n=>cs(n).textOverflow==='ellipsis').length;
  return {shadows,radii:[...radii],numBad,clipped,
    tabular:cs(document.body).fontVariantNumeric.includes('tabular-nums'),
    slaMid:cs(document.documentElement).getPropertyValue('--sla-mid').trim()};
});
const A=[],ok=(c,m)=>A.push((c?'PASS ':'FAIL ')+m);
const dead=tabs.filter(t=>!out[t]||out[t].html<20);
ok(dead.length===0,`every tab renders content (${dead.length?dead.join(','):'all '+tabs.length+' ok'})`);
ok(inv.shadows===0,`phase 1 holds: no shadows (${inv.shadows})`);
ok(inv.radii.every(v=>v==='6px'||v==='20px'||v.includes('%')),`phase 1 holds: one radius + pills (${inv.radii.join(' ')})`);
ok(inv.tabular&&inv.slaMid==='#0D9488',`phase 1 holds: tabular-nums + --sla-mid (${inv.slaMid})`);
ok(inv.numBad===0&&inv.clipped===0,`phase 2 holds: numerics right-aligned (${inv.numBad}) and unclipped (${inv.clipped})`);
ok(errs.length===0,`no pageerror across all ${tabs.length} tabs (${JSON.stringify(errs.slice(0,2))})`);
console.log(A.join('\n'));console.log('\n'+(A.some(x=>x.startsWith('FAIL'))?'RESULT: FAIL':'RESULT: PASS'));
await b.close();process.exit(A.some(x=>x.startsWith('FAIL'))?1:0);
