# Data ingestion

Refresh the console's data from the monthly exports in one step. No filenames or
column positions are hard-coded — each file is recognized by the columns it
carries, so a renamed file still lands correctly.

## Setup (once)

```bash
pip install requests
```

Get the **service-role key**: Supabase → Project Settings → API → `service_role`
(the secret one, *not* the publishable key). It bypasses row-level security so
the loader can write. Keep it out of the repo — pass it as an env var.

## Run

Drop the current exports into a folder (any mix of the six; `.csv` or `.csv.gz`)
and run:

```bash
SUPABASE_SERVICE_KEY=eyJhbGci... python ingest.py ./exports
```

You'll see what it detected and loaded:

```
  detected roster    <- Combined_Clinician_License_Roster.csv
  detected sli       <- Response_Time_Details_By_SLI.csv
  detected consult   <- consult_status_updates.csv.gz
  detected shift     <- Shifts.csv
  detected incentive <- Incentives.csv
  detected license   <- Clinicians_License_Detail.csv
  loaded clinician_roster: 850
  loaded sli_response: 12002
  loaded consult: 176521
  loaded shift: 9594
  loaded incentive: 415
```

The console reads these live, so a browser refresh shows the new data — no
redeploy.

### Dry run (validate without writing)

```bash
DRY_RUN=1 python ingest.py ./exports
```

Detects and transforms everything and prints the row counts, but writes nothing.
Good for confirming a new export parses before you load it.

## What it does

| Detected | Source export | Loads |
|---|---|---|
| `roster` | Combined Clinician License Roster | `clinician_roster` (fused identity) |
| `license` | Clinicians License Detail | feeds identity + licensed states |
| `sli` | Response Time Details By SLI | `sli_response` |
| `consult` | consult_status_updates (Metabase) | `consult` (deduped, modality) |
| `shift` | Shifts | `shift` |
| `incentive` | Incentives | `incentive` |

- **Identity resolution** fuses the roster/license/activity files into one row
  per real clinician (NPI / email / Metabase GUID are gold keys; names only
  bridge when nothing conflicts). See `identity_lib.py`.
- **Consults** are rolled up touch-by-touch into one row each, with modality
  read from the status flow (`in_call` → sync video) and lab work flagged.
- **Idempotent:** each run clears the target rows for that source and reloads,
  so re-running is safe and always reflects the latest export.
- **Volume check.** As the SLI and consult files load, the tool compares each
  partner's row count to the previous load and prints any partner that vanished,
  newly appeared, or swung by more than ~60% — the fingerprint of a partial or
  doubled export. It's advisory (the load still proceeds), so you can eyeball it
  before trusting the numbers:

  ```
    volume check — sli_response vs previous load (2026-06-24):
    ⚠ DISAPPEARED  Acme Health                 1,240 → 0
    ⚠ +118%        Beta Care                     300 → 654
      (18 partners within range)
  ```

## Notes / limits

- **Load the full set together** for a clean monthly refresh. The roster's
  activity stats (consults, last-active, shift hours, incentives) are computed
  across the files present in that run, so dropping *all* current exports in one
  folder gives the most complete roster.
- **Identity memory.** Some clinicians show up only in the activity files (no
  roster/license row, no NPI) and land in the console's **add-to-roster** queue.
  When an admin confirms one from the Clinicians tab, that decision is remembered
  (`roster_decision` table, keyed on a normalized name). On every later run the
  loader reads those confirmations back and marks the person **active** instead
  of re-queuing them — so a partial refresh (say, a solo SLI upload) never
  re-buries someone an admin already vouched for. Obvious non-people from the
  source data (e.g. "Not Assigned") are dropped from the queue automatically.
- **Column renames:** files are matched by column *signatures*, tolerant of
  renamed files and minor column-name drift. A wholesale column rename in a
  source still needs a one-line update to that transform.
- The `service_role` key is powerful — run this from a trusted machine, never
  ship it to the browser.
