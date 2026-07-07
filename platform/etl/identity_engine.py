#!/usr/bin/env python3
"""Clinician identity engine — fuses 6 real exports into one entity per clinician.
Two-pass: (1) union by STRONG keys (npi/email/clinician_guid), (2) attach name-only
records to the single strong entity that shares that normalized name (never over-merge).
Outputs a unified roster + coverage stats + the add-queue of unrostered actives."""
import gzip, csv, re, json
from collections import defaultdict
from datetime import datetime, date, timedelta

B='/root/.claude/uploads/a6460d8f-83c0-5e4a-9439-826dbd972ec2/'
F=dict(roster=B+'b13eb2fb-Combined_Clinician_License_Roster__Combined_Roster.csv',
       lic=B+'4e3dc096-Clinicians_License_Detail_1.csv',
       sli=B+'e7c34be3-Response_Time_Details_By_SLI_Download_80.csv',
       inc=B+'a0e72d7f-July_Incentives.csv',
       shift=B+'313abda8-Shifts_98.csv',
       mb=B+'99464b98-consult_status_updates_with_clinician_20260624T17_56_09.26615400804_00.csv.gz')
OUT='/tmp/claude-0/-home-user-steadymd-workforce/a6460d8f-83c0-5e4a-9439-826dbd972ec2/scratchpad/'
REF=date(2026,7,7); ACTIVE=timedelta(days=90)
CREDS={'md','do','np','pa','fnp','rn','dnp','phd','aprn','crnp','pmhnp','agnp','whnp',
       'msn','apn','bc','ii','iii','jr','sr','faap','facp','dnp','lcsw','psyd'}

def toks(name):
    s=re.sub(r'[,\.\-/|()]',' ',(name or '').lower())
    return frozenset(t for t in s.split() if t and t not in CREDS and len(t)>1)
def nkey(name):
    t=toks(name); return ' '.join(sorted(t)) if t else ''
def cred_of(name):
    m=re.findall(r'\b(MD|DO|NP|PA|FNP|RN|DNP|APRN|PMHNP|AGNP|WHNP|CRNP|PsyD|LCSW)\b',name or '',re.I)
    return m[-1].upper() if m else ''
def pdt(s):
    s=(s or '').strip()
    for f in ('%Y-%m-%d %H:%M:%S','%B %d, %Y, %I:%M %p','%m/%d/%Y %I:%M %p','%Y-%m-%d','%m/%d/%Y'):
        try: return datetime.strptime(s,f)
        except: pass
    return None
def opn(p):
    return gzip.open(p,'rt',encoding='utf-8-sig',errors='replace') if p.endswith('.gz') else open(p,encoding='utf-8-sig',errors='replace')

# ---------- Union-Find over STRONG keys ----------
par={}
def find(x):
    par.setdefault(x,x)
    r=x
    while par[r]!=r: r=par[r]
    while par[x]!=r: par[x],x=r,par[x]
    return r
def union(a,b):
    par[find(a)]=find(b)
def strong_keys(npi=None,email=None,guid=None):
    ks=[]
    if npi and npi.strip().isdigit(): ks.append(('npi',npi.strip()))
    if email and '@' in email: ks.append(('email',email.strip().lower()))
    if guid and len(guid.strip())>=8: ks.append(('guid',guid.strip()))
    return ks

# ---------- PASS 1: gather distinct clinician tuples per source, union strong keys ----------
# each tuple: (name, npi, email, guid, cred, source)
tuples=[]
def add_tuple(name,npi,email,guid,cred,src):
    ks=strong_keys(npi,email,guid)
    for i in range(len(ks)-1): union(ks[i],ks[i+1])
    tuples.append((name,npi,email,guid,cred,src,tuple(ks)))

# roster
with opn(F['roster']) as f:
    for r in csv.DictReader(f):
        add_tuple(r.get('Name'),r.get('NPI'),r.get('Email'),None,r.get('Credential'),'roster')
# license detail (distinct clinicians by npi/email/name)
seen_lic=set()
with opn(F['lic']) as f:
    for r in csv.DictReader(f):
        key=(r.get('Npi'),(r.get('Email') or '').lower(),r.get('First Name'),r.get('Last Name'))
        if key in seen_lic: continue
        seen_lic.add(key)
        nm=f"{r.get('First Name','')} {r.get('Last Name','')}".strip()
        add_tuple(nm,r.get('Npi'),r.get('Email'),None,r.get('Title'),'license')
# metabase distinct clinicians
mb_clin={}
with opn(F['mb']) as f:
    for r in csv.DictReader(f):
        g=r.get('Clinician GUID')
        if g and g not in mb_clin:
            mb_clin[g]=1
            add_tuple(r.get('Clinician Display Name'),None,r.get('Clinician Email'),g,cred_of(r.get('Clinician Display Name')),'metabase')
# incentives distinct
seen=set()
with opn(F['inc']) as f:
    for r in csv.DictReader(f):
        k=(r.get('Clinician Email'),r.get('Clinician Full Name'))
        if k in seen: continue
        seen.add(k)
        add_tuple(r.get('Clinician Full Name'),None,r.get('Clinician Email'),None,r.get('License Type'),'incentive')
# shifts distinct
seen=set()
with opn(F['shift']) as f:
    for r in csv.DictReader(f):
        k=(r.get('User'),r.get('Name'))
        if k in seen: continue
        seen.add(k)
        add_tuple(r.get('Name'),None,r.get('User'),None,None,'shift')
# SLI distinct names (name-only)
sli_names=set()
with opn(F['sli']) as f:
    for r in csv.DictReader(f):
        n=r.get('Clinician')
        if n and n.strip(): sli_names.add(n.strip())

# ---------- NAME-MERGE pass: link strong entities that share a normalized name
# but have NO conflicting NPI (merges roster[NPI-only] with metabase[email/guid-only];
# keeps two-different-NPI people apart). ----------
ent_npi=defaultdict(set); ent_nk=defaultdict(set)
for name,npi,email,guid,cred,src,ks in tuples:
    if not ks: continue
    e=find(ks[0])
    if npi and npi.strip().isdigit(): ent_npi[e].add(npi.strip())
    if name and nkey(name): ent_nk[e].add(nkey(name))
nm=defaultdict(set)
for e,nks in ent_nk.items():
    for k in nks: nm[k].add(find(e))
merged=0
for k,ents in nm.items():
    ents={find(e) for e in ents}
    if len(ents)<2: continue
    npis=set().union(*[ent_npi.get(e,set()) for e in ents])
    if len(npis)<=1:                                # no NPI conflict -> same person
        el=list(ents)
        for e in el[1:]:
            if find(el[0])!=find(e): union(el[0],e); merged+=1
print(f"name-merge unified {merged} split entities (roster<->metabase bridge)")

# ---------- Build final name -> entity index ----------
name2ent=defaultdict(set)
for name,npi,email,guid,cred,src,ks in tuples:
    if ks and name and nkey(name):
        name2ent[nkey(name)].add(find(ks[0]))

def entity_of(name,ks):
    if ks: return find(ks[0])
    k=nkey(name)
    ents={find(e) for e in name2ent.get(k,())}
    if len(ents)==1: return next(iter(ents))
    if len(ents)>1: return ('AMBIG',k)              # name maps to 2+ different-NPI people
    return ('NAMEONLY',k)                           # not in roster/strong sources -> add-queue

# ---------- Aggregate entity attributes ----------
E=defaultdict(lambda: dict(names=set(),creds=set(),npis=set(),emails=set(),guids=set(),
    lic_states=set(),act_states=set(),partners=set(),programs=set(),modalities=set(),
    consults=set(),shift_hours=0.0,incentive=0.0,last=None,sources=set()))
def touch(ent,last=None,**kw):
    e=E[ent]
    for k,v in kw.items():
        if v is None or v=='': continue
        if k in ('shift_hours','incentive'): e[k]+=v
        elif isinstance(e[k],set):
            (e[k].update(v) if isinstance(v,(set,list)) else e[k].add(v))
    if last and (e['last'] is None or last>e['last']): e['last']=last

# re-walk tuples to seed identity attrs
for name,npi,email,guid,cred,src,ks in tuples:
    ent=entity_of(name,ks)
    touch(ent,names=name.strip() if name else None,creds=(cred or '').strip().upper() or None,
          npis=(npi.strip() if npi and npi.strip().isdigit() else None),
          emails=(email.strip().lower() if email and '@' in email else None),
          guids=(guid.strip() if guid and len(str(guid))>=8 else None),sources=src)

# ---------- Stream activity files for coverage (last_active, consults, states, programs) ----------
def act_entity(name=None,npi=None,email=None,guid=None):
    return entity_of(name,strong_keys(npi,email,guid))
# metabase (touch rollup: distinct consult guids, programs, partners, modalities, last status date)
with opn(F['mb']) as f:
    for r in csv.DictReader(f):
        ent=act_entity(r.get('Clinician Display Name'),None,r.get('Clinician Email'),r.get('Clinician GUID'))
        d=pdt(r.get('Consult Status Created At'))
        touch(ent,last=d.date() if d else None,partners=r.get('Partner Name'),programs=r.get('Program Name'),
              modalities=r.get('Consult Type'),consults=r.get('Consult GUID'),sources='metabase-act')
# SLI (name-only -> resolved via index)
with opn(F['sli']) as f:
    for r in csv.DictReader(f):
        ent=act_entity(r.get('Clinician'))
        d=pdt(r.get('SLI Completed')) or pdt(r.get('SLI Received'))
        dd=d.date() if d else None
        st=(r.get('State') or '').strip()
        touch(ent,last=dd,partners=r.get('Partner'),programs=r.get('Program Name'),
              modalities=r.get('Consult Type'),consults=r.get('Consult GUID'),
              act_states=(st if st and dd and dd>=REF-ACTIVE else None),sources='sli-act')
# incentives
with opn(F['inc']) as f:
    for r in csv.DictReader(f):
        ent=act_entity(r.get('Clinician Full Name'),None,r.get('Clinician Email'))
        d=pdt(r.get('Launched Time')); dd=d.date() if d else None
        try: amt=float(r.get('Amount') or 0)
        except: amt=0.0
        st=(r.get('States') or '').strip()
        touch(ent,last=dd,partners=r.get('Partner Name'),programs=r.get('Program Name'),
              modalities=r.get('Consult Type'),incentive=amt,
              act_states=(st if st and dd and dd>=REF-ACTIVE else None),sources='inc-act')
# shifts (hours)
with opn(F['shift']) as f:
    for r in csv.DictReader(f):
        ent=act_entity(r.get('Name'),None,r.get('User'))
        d=pdt(r.get('End Time'));
        try: hrs=float(r.get('Hours') or 0)
        except: hrs=0.0
        touch(ent,last=d.date() if d else None,shift_hours=hrs,sources='shift-act')
# license -> licensed states
with opn(F['lic']) as f:
    for r in csv.DictReader(f):
        ent=act_entity(f"{r.get('First Name','')} {r.get('Last Name','')}".strip(),r.get('Npi'),r.get('Email'))
        st=(r.get('License State') or '').strip()
        if st: touch(ent,lic_states=st)
# roster licensed states (from the "Licensed States" comma list)
with opn(F['roster']) as f:
    for r in csv.DictReader(f):
        ent=act_entity(r.get('Name'),r.get('NPI'),r.get('Email'))
        for st in (r.get('Licensed States') or '').split(','):
            st=st.strip()
            if st: touch(ent,lic_states=st)

# ---------- Report ----------
real=[e for k,e in E.items() if k[0] in ('npi','email','guid')]  # strong entities
nameonly=[(k,e) for k,e in E.items() if k[0]=='NAMEONLY']
ambig=[(k,e) for k,e in E.items() if k[0]=='AMBIG']
def is_active(e): return e['last'] is not None and e['last']>=REF-ACTIVE
in_roster=[e for e in real if 'roster' in e['sources']]
overmerge=[e for e in real if len(e['npis'])>1]

print(f"UNIFIED CLINICIAN ENTITIES: {len(real)} strong + {len(nameonly)} name-only(add-queue) + {len(ambig)} name-collisions")
print(f"  in curated roster: {len(in_roster)}   |   discovered from activity, NOT in roster: {len(real)-len(in_roster)+len(nameonly)}")
print(f"  key coverage — NPI: {sum(1 for e in real if e['npis'])}  email: {sum(1 for e in real if e['emails'])}  clinician_guid: {sum(1 for e in real if e['guids'])}")
print(f"  active (consult in 90d): {sum(1 for e in real if is_active(e))}   inactive: {sum(1 for e in real if not is_active(e))}")
print(f"  name-collision flags (>1 NPI in one entity): {len(overmerge)}")
print(f"  ADD-QUEUE (active by name, not in roster): {len(nameonly)}  e.g. {[k[1] for k,_ in nameonly[:6]]}")

def best_name(e):
    return max(e['names'],key=len) if e['names'] else ''
cols=['canonical_name','credential','npi','emails','clinician_guids','name_aliases',
      'licensed_states','active_states_90d','programs','partners','modalities',
      'consults_touched','shift_hours','incentive_usd','last_active','status','sources']
with open(OUT+'unified_clinician_roster.csv','w',newline='') as f:
    w=csv.writer(f); w.writerow(cols)
    allents=[(False,e) for e in real]+[(True,e) for k,e in nameonly]
    for isq,e in sorted(allents,key=lambda x:(-len(x[1]['consults']), best_name(x[1]).lower())):
        w.writerow([best_name(e),'|'.join(sorted(c for c in e['creds'] if c)),'|'.join(sorted(e['npis'])),
            '|'.join(sorted(e['emails'])),'|'.join(sorted(e['guids'])),
            ' ; '.join(sorted(n for n in e['names'] if n)),
            ','.join(sorted(e['lic_states'])),','.join(sorted(e['act_states'])),
            ' | '.join(sorted(p for p in e['programs'] if p)),' | '.join(sorted(p for p in e['partners'] if p)),
            ' | '.join(sorted(m for m in e['modalities'] if m)),
            len(e['consults']),round(e['shift_hours'],1),round(e['incentive'],2),
            e['last'].isoformat() if e['last'] else '',
            ('ADD-TO-ROSTER' if isq else ('active' if is_active(e) else 'inactive')),
            ','.join(sorted(e['sources']))])
print('\nWROTE', OUT+'unified_clinician_roster.csv', f'({len(real)+len(nameonly)} rows)')
# a couple of showcase rows
show=sorted(real,key=lambda e:-len(e['consults']))[:3]
for e in show:
    print(f"  · {best_name(e):26} {'/'.join(sorted(e['creds'])) or '?':5} NPI={next(iter(e['npis']),'-'):11} "
          f"states_lic={len(e['lic_states'])} consults={len(e['consults'])} last={e['last']} src={sorted(e['sources'])}")
