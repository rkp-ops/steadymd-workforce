# `ingest` Edge Function — in-console data refresh

This is what makes the monthly data refresh a **console button instead of a
terminal command**. The admin drops the exports in the console's **Import** tab;
the browser uploads them to the private `imports` Storage bucket and invokes
this function, which parses, transforms, loads (service role, server-side), and
re-anchors the clinician spine — then returns a report. **The database service
key lives only in this function's server-side env, never in the browser.**

## Files

| File | What it is |
|---|---|
| `core.mjs` | The **pure** ingestion logic — date parsing, file detection, modality, and the union-find roster engine. No Deno/Node imports, so it runs in both the Edge runtime and the Node conformance harness. This is a faithful port of `platform/ingest/identity_lib.py` + the pure helpers of `ingest.py`. |
| `index.ts` | The Deno IO + handler layer: Storage download, CSV parse/stream, REST load, `relink_clinician_spine()`, volume checks, admin gating, and the request handler. Imports all pure logic from `core.mjs`. |

## Why a port, and how divergence is prevented

`platform/ingest/` (Python) is the reference implementation and still works as a
CLI for bulk/automation. This function is the port that runs the same logic
server-side for the browser. To keep the two from drifting, the correctness-
critical roster engine is verified by **output-equivalence**: a harness runs the
Python `build_roster` and the JS `core.mjs` `buildRoster` on identical synthetic
fixtures (strong-key union, name-bridge merge, name-only add-to-roster, tiering,
`needs`, overrides, confirmations) and diffs them. They must match exactly.

Run it (needs Python 3 + Node):

```bash
node scratchpad/roster_conformance.mjs   # or wherever the harness lives
```

If you change the roster algorithm, change it in **both** `core.mjs` and
`identity_lib.py`, and re-run the harness until it prints `ALL CONFORMANCE
CHECKS PASSED`.

## Modes

- `{ mode: 'dry',  paths: [...] }` — detect + count, **writes nothing** (Preview).
- `{ mode: 'load', paths: [...] }` — replace each source, load, and relink.
- `{ mode: 'roster-test', files: { roster: '<csv text>', ... } }` — inline
  fixtures, returns the resolved roster only. Used by the conformance smoke-test
  against the deployed function; no auth, no data access, writes nothing.

`dry`/`load` require an **active admin** caller (the function validates the
caller's JWT via `whoami`). The consult file **streams** with an incremental
rollup, so the 500k-row export fits the isolate.

## Deploy / update

Deployed via the Supabase MCP `deploy_edge_function` (both files, entrypoint
`index.ts`, `verify_jwt: false` — the function does its own admin gating).
There is no Supabase CLI in the sandbox, so redeploys go through the MCP tool
with the file contents inline. After deploying, smoke-test with the
`roster-test` mode and confirm the roster matches the Node/Python golden.
