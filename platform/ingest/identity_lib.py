#!/usr/bin/env python3
"""Clinician identity resolution, packaged for the ingestion tool.

build_roster(found, ref, active) fuses whichever of the recognized exports are
present into one entity per real clinician and returns rows in the
clinician_roster table shape, plus an {email: credential} map for the shift load.

Strategy (unchanged from the proven engine):
  pass 1  union records by STRONG keys — NPI, email, Metabase GUID
  pass 2  bridge strong entities that share a normalized name with no conflicting
          NPI (joins an NPI-only roster row to an email/GUID-only activity row,
          but never merges two people who carry different NPIs)
  then    aggregate attributes and stream the activity files for coverage
Names never override a strong key, so a hyphenated/split/renamed name can't merge
two people or split one.
"""
import csv, gzip, re
from collections import defaultdict
from datetime import datetime

CREDS = {'md','do','np','pa','fnp','rn','dnp','phd','aprn','crnp','pmhnp','agnp','whnp',
         'msn','apn','bc','ii','iii','jr','sr','faap','facp','lcsw','psyd','arnp',
         'ma','cma','rma','lpn','cnp','anp','acnp','agacnp','agpcnp','apnp','ms','gc'}

# every credential we recognize in a name suffix or a Credential column
_CRED_RE = re.compile(r'\b(MD|DO|PA|FNP|PMHNP|AGACNP|AGPCNP|AGNP|WHNP|ACNP|APRN|ARNP|CRNP|'
                      r'DNP|CNP|ANP|APNP|APN|NP|CMA|RMA|MA|LPN|RN|MSN|MS|GC|PSYD|PHD|LCSW)\b', re.I)
# tier a clinician by capacity. seat = prescriber who can own a full seat (MD/DO/PA and
# the whole NP/APRN family). support = touches consults but not a seat (MA, RN, etc.).
# MA is support by definition — it can NEVER count toward coverage.
_SEAT = {'MD', 'DO', 'PA'}
def _tier(cred):
    if not cred: return None
    c = cred.upper().replace('-', '').replace('.', '')
    if c in _SEAT or 'NP' in c or 'APRN' in c or 'ARNP' in c or 'CRNP' in c or 'DNP' in c or c in ('APN', 'APNP'):
        return 'seat'
    return 'support'

def _opn(p):
    return gzip.open(p,'rt',encoding='utf-8-sig',errors='replace') if p.endswith('.gz') \
        else open(p,encoding='utf-8-sig',errors='replace')
def _toks(name):
    x = re.sub(r'[,\.\-/|()]',' ',(name or '').lower())
    return frozenset(t for t in x.split() if t and t not in CREDS and len(t) > 1)
def _nkey(name):
    t = _toks(name); return ' '.join(sorted(t)) if t else ''
def _cred_of(name):
    if not name: return ''
    tail = name.rsplit(',', 1)[-1] if ',' in name else name   # credentials trail the name
    m = _CRED_RE.findall(tail) or _CRED_RE.findall(name)
    return m[-1].upper() if m else ''
def _pdt(v):
    v = (v or '').strip()
    for f in ('%Y-%m-%d %H:%M:%S','%B %d, %Y, %I:%M %p','%m/%d/%Y %I:%M %p','%Y-%m-%d','%m/%d/%Y','%m/%d/%Y %I:%M %p'):
        try: return datetime.strptime(v,f)
        except: pass
    return None
def _rows(p):
    with _opn(p) as f:
        yield from csv.DictReader(f)

def build_roster(found, ref, active, confirmed=frozenset(), overrides=None):
    # `confirmed` = name_keys an admin confirmed into the roster (identity memory);
    # such name-only clinicians come back active instead of ADD-TO-ROSTER.
    # `overrides` = {name_key: {'credential':str, 'states':[..], 'removed':bool}} —
    # admin corrections that win over the source data and persist across refreshes.
    overrides = overrides or {}
    par = {}
    def find(x):
        par.setdefault(x,x); r = x
        while par[r] != r: r = par[r]
        while par[x] != r: par[x], x = r, par[x]
        return r
    def union(a,b): par[find(a)] = find(b)
    def strong_keys(npi=None, email=None, guid=None):
        ks = []
        if npi and npi.strip().isdigit(): ks.append(('npi', npi.strip()))
        if email and '@' in email: ks.append(('email', email.strip().lower()))
        if guid and len(guid.strip()) >= 8: ks.append(('guid', guid.strip()))
        return ks

    tuples = []
    def add_tuple(name, npi, email, guid, cred, src):
        ks = strong_keys(npi, email, guid)
        for i in range(len(ks)-1): union(ks[i], ks[i+1])
        tuples.append((name, npi, email, guid, cred, src, tuple(ks)))

    ro, li, mb, sl, inc, sh = (found.get(k) for k in ('roster','license','consult','sli','incentive','shift'))

    if ro:
        for r in _rows(ro): add_tuple(r.get('Name'), r.get('NPI'), r.get('Email'), None, r.get('Credential'), 'roster')
    if li:
        seen = set()
        for r in _rows(li):
            key = (r.get('Npi'), (r.get('Email') or '').lower(), r.get('First Name'), r.get('Last Name'))
            if key in seen: continue
            seen.add(key)
            add_tuple(f"{r.get('First Name','')} {r.get('Last Name','')}".strip(), r.get('Npi'), r.get('Email'), None, r.get('Title'), 'license')
    if mb:
        seen = set()
        for r in _rows(mb):
            g = r.get('Clinician GUID')
            if g and g not in seen:
                seen.add(g)
                add_tuple(r.get('Clinician Display Name'), None, r.get('Clinician Email'), g, _cred_of(r.get('Clinician Display Name')), 'metabase')
    if inc:
        seen = set()
        for r in _rows(inc):
            k = (r.get('Clinician Email'), r.get('Clinician Full Name'))
            if k in seen: continue
            seen.add(k)
            add_tuple(r.get('Clinician Full Name'), None, r.get('Clinician Email'), None, r.get('License Type'), 'incentive')
    if sh:
        seen = set()
        for r in _rows(sh):
            k = (r.get('User'), r.get('Name'))
            if k in seen: continue
            seen.add(k)
            add_tuple(r.get('Name'), None, r.get('User'), None, None, 'shift')

    # name-merge bridge
    ent_npi = defaultdict(set); ent_nk = defaultdict(set)
    for name, npi, email, guid, cred, src, ks in tuples:
        if not ks: continue
        e = find(ks[0])
        if npi and npi.strip().isdigit(): ent_npi[e].add(npi.strip())
        if name and _nkey(name): ent_nk[e].add(_nkey(name))
    by_name = defaultdict(set)
    for e, nks in ent_nk.items():
        for k in nks: by_name[k].add(find(e))
    for k, ents in by_name.items():
        ents = {find(e) for e in ents}
        if len(ents) < 2: continue
        npis = set().union(*[ent_npi.get(e, set()) for e in ents])
        if len(npis) <= 1:
            el = list(ents)
            for e in el[1:]:
                if find(el[0]) != find(e): union(el[0], e)

    name2ent = defaultdict(set)
    for name, npi, email, guid, cred, src, ks in tuples:
        if ks and name and _nkey(name): name2ent[_nkey(name)].add(find(ks[0]))
    def entity_of(name, ks):
        if ks: return find(ks[0])
        k = _nkey(name); ents = {find(e) for e in name2ent.get(k, ())}
        if len(ents) == 1: return next(iter(ents))
        if len(ents) > 1: return ('AMBIG', k)
        return ('NAMEONLY', k)

    E = defaultdict(lambda: dict(names=set(),creds=set(),npis=set(),emails=set(),guids=set(),
        lic_states=set(),act_states=set(),partners=set(),programs=set(),modalities=set(),
        consults=set(),shift_hours=0.0,incentive=0.0,last=None,sources=set()))
    def touch(ent, last=None, **kw):
        e = E[ent]
        for k, v in kw.items():
            if v is None or v == '': continue
            if k in ('shift_hours','incentive'): e[k] += v
            elif isinstance(e[k], set):
                e[k].update(v) if isinstance(v,(set,list)) else e[k].add(v)
        if last and (e['last'] is None or last > e['last']): e['last'] = last

    for name, npi, email, guid, cred, src, ks in tuples:
        ent = entity_of(name, ks)
        touch(ent, names=name.strip() if name else None, creds=(cred or '').strip().upper() or None,
              npis=(npi.strip() if npi and npi.strip().isdigit() else None),
              emails=(email.strip().lower() if email and '@' in email else None),
              guids=(guid.strip() if guid and len(str(guid)) >= 8 else None), sources=src)

    def act(name=None, npi=None, email=None, guid=None): return entity_of(name, strong_keys(npi, email, guid))
    if mb:
        for r in _rows(mb):
            e = act(r.get('Clinician Display Name'), None, r.get('Clinician Email'), r.get('Clinician GUID'))
            d = _pdt(r.get('Consult Status Created At'))
            touch(e, last=d.date() if d else None, partners=r.get('Partner Name'), programs=r.get('Program Name'),
                  modalities=r.get('Consult Type'), consults=r.get('Consult GUID'))
    if sl:
        for r in _rows(sl):
            e = act(r.get('Clinician')); d = _pdt(r.get('SLI Completed')) or _pdt(r.get('SLI Received'))
            dd = d.date() if d else None; st = (r.get('State') or '').strip()
            touch(e, last=dd, names=(r.get('Clinician') or '').strip() or None,
                  partners=r.get('Partner'), programs=r.get('Program Name'), modalities=r.get('Consult Type'),
                  consults=r.get('Consult GUID'), act_states=(st if st and dd and dd >= ref-active else None))
    if inc:
        for r in _rows(inc):
            e = act(r.get('Clinician Full Name'), None, r.get('Clinician Email'))
            d = _pdt(r.get('Launched Time')); dd = d.date() if d else None; st = (r.get('States') or '').strip()
            try: amt = float(r.get('Amount') or 0)
            except: amt = 0.0
            touch(e, last=dd, partners=r.get('Partner Name'), programs=r.get('Program Name'),
                  modalities=r.get('Consult Type'), incentive=amt, act_states=(st if st and dd and dd >= ref-active else None))
    if sh:
        for r in _rows(sh):
            e = act(r.get('Name'), None, r.get('User')); d = _pdt(r.get('End Time'))
            try: hrs = float(r.get('Hours') or 0)
            except: hrs = 0.0
            touch(e, last=d.date() if d else None, shift_hours=hrs)
    if li:
        for r in _rows(li):
            e = act(f"{r.get('First Name','')} {r.get('Last Name','')}".strip(), r.get('Npi'), r.get('Email'))
            st = (r.get('License State') or '').strip()
            if st: touch(e, lic_states=st)
    if ro:
        for r in _rows(ro):
            e = act(r.get('Name'), r.get('NPI'), r.get('Email'))
            for st in (r.get('Licensed States') or '').split(','):
                st = st.strip()
                if st: touch(e, lic_states=st)

    def is_active(e): return e['last'] is not None and e['last'] >= ref-active
    def best_name(e): return max(e['names'], key=len) if e['names'] else '(unknown)'
    def one_cred(e):
        cs = [c for c in e['creds'] if c]
        return max(cs, key=len) if cs else None

    # placeholder "clinicians" from the source data — never real people to triage
    NONPERSON = {'assigned not', 'assigned unassigned', 'na', 'test'}
    rows = []; cred_by_email = {}
    for k, e in E.items():
        strong = isinstance(k, tuple) and k and k[0] in ('npi','email','guid')
        nameonly = isinstance(k, tuple) and k and k[0] == 'NAMEONLY'
        if not (strong or nameonly): continue                # drop AMBIG name-collisions
        on_roster = bool(e['sources'] & {'roster', 'license'})
        if nameonly:
            if k[1] in NONPERSON: continue                   # drop "Not Assigned" et al.
            # name-only, not on the roster, and never seen working = noise, not a person
            if not on_roster and e['last'] is None: continue
        nm = best_name(e)
        nk = k[1] if nameonly else _nkey(nm)
        cred = one_cred(e); states = sorted(e['lic_states'])
        ov = overrides.get(nk)
        if ov:
            if ov.get('removed'): continue                   # admin removed this person
            if ov.get('credential'): cred = ov['credential']
            if ov.get('states') is not None: states = sorted(set(ov['states']))   # admin's set wins
        conf = nk in confirmed
        for em in e['emails']:
            if em and cred: cred_by_email.setdefault(em, cred)
        # tier drives capacity/coverage; support (MA/RN…) never counts as a seat
        tier = _tier(cred)
        needs = []
        if not cred: needs.append('credential')
        if tier == 'seat' and not states: needs.append('state')   # seats hold state licenses; support don't
        # add-to-roster queue = seen working in activity but absent from roster/license,
        # and not yet confirmed. Already-on-file people are on the roster, not queued.
        addq = nameonly and not on_roster and not conf and e['last'] is not None
        if addq:               status = 'ADD-TO-ROSTER'
        elif needs:            status = 'NEEDS-CORRECTION'      # on the roster but incomplete
        elif conf or is_active(e): status = 'active'
        else:                  status = 'inactive'
        rows.append({
            "name": nm, "credential": cred, "tier": tier, "needs": needs,
            "npi": next(iter(sorted(e['npis'])), None),
            "emails": sorted(e['emails']), "aliases": sorted(n for n in e['names'] if n),
            "license_states": states, "active_states": sorted(e['act_states']),
            "programs": sorted(p for p in e['programs'] if p), "partners": sorted(p for p in e['partners'] if p),
            "modalities": sorted(m for m in e['modalities'] if m),
            "consult_count": len(e['consults']), "shift_hours": round(e['shift_hours'], 1),
            "incentive_usd": round(e['incentive'], 2),
            "last_active": e['last'].isoformat() if e['last'] else None,
            "status": status,
        })
    return rows, cred_by_email
