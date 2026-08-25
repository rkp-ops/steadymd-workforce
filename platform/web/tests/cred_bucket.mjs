// credClass must agree with the database's cred_bucket on every raw credential
// actually present, must be idempotent on bucket names, and must never invent
// a bucket for something it does not recognise.
import pw from '/opt/node22/lib/node_modules/playwright/index.js';
const {chromium}=pw; import {pathToFileURL} from 'url';
import {resolve,dirname} from 'path'; import {fileURLToPath} from 'url';
const PAGE=resolve(dirname(fileURLToPath(import.meta.url)),'../../../public/console-live.html');
let pass=0,fail=0; const ok=(c,m)=>{c?(pass++,console.log('PASS '+m)):(fail++,console.log('FAIL '+m))};
// (credential, expected bucket) straight from clinician_roster + cred_bucket()
const DB=[['NP','NP'],['MD','Doctor'],['FNP','NP'],['APRN','NP'],['DO','Doctor'],['FNP-BC','NP'],
['FNP-C','NP'],['ARNP','NP'],['APRN-CNP','NP'],['APN','NP'],['CRNP','NP'],['MA','MA'],['CNP','NP'],
['DNP','NP'],['NP-C','NP'],['A-P-N-P','NP'],['ANP','NP'],['ACNP','NP'],['AC-CRNP-A','NP'],
['AGPCNP-BC','NP'],['APNP','NP'],['GC','GC'],['AGNP-C','NP'],['PA','PA'],['ANP-BC','NP'],
['APRN-NP','NP'],['AGPCNP','NP'],['ACNP-BC','NP'],['AC-CRNP-PMH','NP'],['AGACNP-BC','NP'],
['TLHT-APRN','NP'],['AC-CRNP-AC','NP'],['MS','MS']];
const b=await chromium.launch(); const p=await b.newPage();
await p.goto(pathToFileURL(PAGE).href,{waitUntil:'domcontentloaded'}); await p.waitForTimeout(200);
const got=await p.evaluate(D=>D.map(([raw])=>credClass(raw)),DB);
const bad=DB.map(([raw,exp],i)=>({raw,exp,got:got[i]})).filter(x=>x.got!==x.exp);
ok(bad.length===0,`all ${DB.length} real credentials match the database buckets${bad.length?' -> '+JSON.stringify(bad):''}`);
// idempotent on bucket names - this is the Doctor->NP bug
const buckets=['Doctor','NP','PA','MA','GC','MS'];
const round=await p.evaluate(B=>B.map(x=>credClass(x)),buckets);
ok(JSON.stringify(round)===JSON.stringify(buckets),`bucket names pass through unchanged (${JSON.stringify(round)})`);
// unknown must not become NP
const unk=await p.evaluate(()=>['ZZZ','Unspecified','—','','RN','LPN'].map(x=>credClass(x)));
ok(unk.every(x=>x===''),`unrecognised values return blank, never NP (${JSON.stringify(unk)})`);
// re-bucketing an already-bucketed list must not merge rows
const merged=await p.evaluate(()=>credBucket(
  [{name:'NP',hours:1004,shifts:183},{name:'Doctor',hours:343.5,shifts:57}],['hours','shifts']));
ok(merged.length===2,`bucketed rows stay separate (${merged.length} rows)`);
ok(merged.find(x=>x.name==='Doctor')?.hours===343.5,'Doctor hours are not absorbed into NP');
ok(merged.find(x=>x.name==='NP')?.hours===1004,'NP hours are unchanged');
console.log(`\n${fail?'RESULT: FAIL':'RESULT: PASS'} (${pass} passed, ${fail} failed)`);
await b.close(); process.exit(fail?1:0);
