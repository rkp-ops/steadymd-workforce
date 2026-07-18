# Working notes for Claude

## Design bar (standing preference — the user pays per token; waste is disrespect)

Every element I put on screen must **earn its place**: it has to be readable,
actionable, and repurposable. If a chart/panel/tile can't be read at a glance,
drilled into, or used to make a decision, it is *space-filling* and must not
exist. Decorative or "looks like analytics" filler is a failure — it wastes the
user's time and money and erodes trust. Before adding any visual, I state (to
myself) what decision it supports; if I can't, I don't build it.

- **Never show raw seconds** (or any machine-unit) for a human-facing duration.
  Wait/response/handle times are always human-readable — `12m`, `1h 10m`,
  `2d 3h`. Seconds are a computer's unit, not a reader's. This is non-negotiable.
- **Order lists for the human, not the machine.** Filters, dropdowns, and any
  pick-list a person scans are **alphabetical** (or another human-sensible
  order), never sorted by row-count/volume just because that's what the query
  returned. Volume ranking is fine for *ranked insight lists*, not for *pickers*.
- Concretely retired for these reasons: the Overview "SLA by day" chart
  (unreadable, undrillable, pure filler). Don't reintroduce that class of thing.

## Handing off manual steps (standing preference)

Whenever a task needs a step **the user has to do by hand** — anything I can't
finish myself in this environment — write it up as a ready-to-run block, not
prose. Every time, include:

1. **Numbered steps, in the exact order to do them.**
2. **The exact text to paste into each box**, in its own copy-friendly code
   block, labeled with where it goes (file path, commit message, PR title/body,
   SQL editor, form field, …).
3. **Where each file goes** — full repo path, and a note when it replaces an
   existing file.

Don't make the user infer the order, retype a message, or guess a path.

## What I can and can't do myself here

- **Git push works.** The Claude GitHub App is installed on
  `rkp-ops/steadymd-workforce` with write access, so I push branches and open
  PRs directly (that's how PRs #1–#3 landed). No more hand-upload of files.
- **Netlify deploys are repo-connected and automatic.** The site builds from
  this repo on every push to `main` — I don't upload build artifacts, and the
  sandbox CLI/API deploy paths are all blocked (build deploy 403s: no build-bot
  permission; the MCP deploy proxy forbids direct API calls; no Netlify token
  exists in the sandbox). So new front-end ships by pushing to `main`, not by
  deploying from here — which is why the console lives on the one repo-connected
  site (below) rather than a fresh site I'd have to hand-link.
- **The database I can change directly.** Supabase schema and data go through
  the Supabase tooling and take effect live — not manual steps, no upload.

## The Netlify site (`performance-tracking-console`, auto-deploys from `main`)

One repo-connected site, publishing `public/` on every push to `main`:

| URL | Serves |
|---|---|
| `performance-tracking-console.netlify.app/` | the operations console — the landing/home. A `public/_redirects` rule rewrites `/` → `/console-live.html` (forced with `200!` so it wins over `public/index.html`). |
| `…/console-live.html` | the same console, direct path (back-compat for old links). |
| `…/index.html` | the legacy Workforce Intelligence React app (`public/index.html`), kept live for the pending audit. |

This is the site formerly named `steadymd-workforce`, renamed twice via the
Netlify MCP (`update-project-name`) — first to `steadymd-performance-tracking`,
then to `performance-tracking-console` (dropping the `steadymd` prefix). The old
`steadymd-workforce.netlify.app` hostname retired with the rename; the site
reuses that original repo connection, so there was nothing to hand-link. A
separate empty site that briefly held the `steadymd-performance-tracking` name
was parked aside as `steadymd-perf-tracking-old`, and the `operational/` folder
is now vestigial (kept only so the old separate-site path still builds if ever
revived).

Note: this site has a Netlify visitor-access password in front of the console's
own Supabase login (carried over from the workforce site). Toggle it with the
Netlify MCP `update-visitor-access-controls` if a password-free landing is
wanted — the real auth gate is the console's Supabase sign-in + RLS.

## Deploy checklist (front end)

1. If the template changed, rebuild: `python platform/web/build_live.py`
   (reads `platform/web/console.tpl.html` → writes `public/console-live.html`,
   which is what `/` serves). It also writes `operational/index.html`; that copy
   is vestigial now but harmless.
2. Commit and push to `main` (open a PR; merge it).
3. The site redeploys automatically on the push — no upload.
