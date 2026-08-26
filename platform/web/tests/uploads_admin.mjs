// Loaded-uploads admin panel: list what's been loaded and remove one.
import pw from '/opt/node22/lib/node_modules/playwright/index.js';
const {chromium}=pw; import {pathToFileURL} from 'url';
import {resolve,dirname} from 'path'; import {fileURLToPath} from 'url';
const PAGE=resolve(dirname(fileURLToPath(import.meta.url)),'../../../public/console-live.html');
const errs=[]; const b=await chromium.launch(); const p=await b.newPage({viewport:{width:1320,height:1000}});
p.on('pageerror',e=>errs.push('PAGEERR: '+e.message));
p.on('console',m=>{if(m.type()==='error'&&!/ERR_(CONNECTION|NETWORK|NAME_NOT)|Failed to load resource/.test(m.text()))errs.push('CONSOLE: '+m.text())});
p.on('dialog',d=>d.accept());   // auto-accept the confirm()
await p.goto(pathToFileURL(PAGE).href,{waitUntil:'domcontentloaded'});
await p.waitForTimeout(200);
await p.evaluate(()=>{
  const R=o=>Object.assign({em:[],al:[],mo:[],as:[],pa:[],pr:['P'],sh:0,inc:0,needs:[],tier:'seat',st:'active',la:'2026-07-16',ls:['TX'],npi:'1'},o);
  window.__init([],null,[R({rid:'1',n:'A B',c:'MD',ct:5})],
   {loaded:{min:'2026-08-25',max:'2026-08-31'},range:{min:'2026-08-25',max:'2026-08-31'},
    by_service_line:[{name:'CSL',hours:8,shifts:1}],by_cred:[{name:'NP',hours:8,shifts:1}],top_clin:[],total_hours:8,n_shifts:1,n_clinicians:1},
   null,null,null,null,null,[]);
});
// become import-admin with a mock API; capture deleteUpload calls
await p.evaluate(()=>{
  const g=document.getElementById('authgate'); if(g)g.classList.add('hide');
  window.__DEL=[];
  window.__setImportAdmin(true, {
    upload:async()=>'x', run:async()=>({}), reconcile:async()=>[],
    listUploads: async()=>[
      {kind:'shift',filename:'Shifts - 2026-08-26.csv',parts:2,last_uploaded_at:'2026-08-26T16:51:01Z'},
      {kind:'sli_response',filename:'CSL Async.csv',parts:1,last_uploaded_at:'2026-07-20T20:37:04Z'}],
    deleteUpload: async(kind,fn)=>{window.__DEL.push([kind,fn]);return {ok:true,kind,filename:fn,deleted:{shift:5230,source_upload:2}}}
  });
});
await p.evaluate(()=>go('import')); await p.waitForTimeout(200);

const A=[],ok=(c,m)=>A.push((c?'PASS ':'FAIL ')+m);

const rows=await p.$$eval('#impUploads [data-uk]',els=>els.map(e=>({
  kind:e.dataset.uk, file:e.dataset.uf, hasRemove:!!e.querySelector('[data-up-rm]'), text:e.textContent.replace(/\s+/g,' ').trim()})));
ok(rows.length===2 && rows[0].file==='Shifts - 2026-08-26.csv' && rows[0].hasRemove,'lists loaded uploads with a Remove on each ('+rows.length+')');
ok(/2 parts/.test(rows[0].text) && /Aug 26, 2026/.test(rows[0].text),'shows kind, parts and a human date ('+rows[0].text+')');
await p.screenshot({path:resolve(dirname(fileURLToPath(import.meta.url)),'uploads_admin.png')});

// remove the first upload
await p.click('#impUploads [data-uk] [data-up-rm]');
await p.waitForTimeout(250);
const del=await p.evaluate(()=>window.__DEL);
ok(del.length===1 && del[0][0]==='shift' && del[0][1]==='Shifts - 2026-08-26.csv','Remove calls deleteUpload(kind, filename) exactly ('+JSON.stringify(del)+')');
const removedText=await p.$eval('#impUploads',e=>e.textContent);
ok(/Removed/.test(removedText),'row confirms removal inline');

ok(errs.length===0,'no pageerror/console error ('+JSON.stringify(errs.slice(0,2))+')');
console.log(A.join('\n'));console.log('\n'+(A.some(x=>x.startsWith('FAIL'))?'RESULT: FAIL':'RESULT: PASS'));
await b.close();process.exit(A.some(x=>x.startsWith('FAIL'))?1:0);
