# Working notes for Claude

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
- **Netlify deploys are repo-connected and automatic.** Both sites build from
  this repo on every push to `main` — I don't upload build artifacts, and the
  sandbox CLI/API deploy paths are blocked (build deploy 403s: no build-bot
  permission; the MCP deploy proxy forbids direct API calls). The only thing I
  can't do is create the *initial* repo↔site link — that's a one-time step in
  the Netlify UI (see below).
- **The database I can change directly.** Supabase schema and data go through
  the Supabase tooling and take effect live — not manual steps, no upload.

## The two Netlify sites (both auto-deploy from `main`)

| Site | Build setting | Serves |
|---|---|---|
| `steadymd-performance-tracking.netlify.app` | **Base directory `operational`** (reads `operational/netlify.toml`, publish `.`) | the console at `/` — the proper landing/home |
| `steadymd-workforce.netlify.app` | root `netlify.toml`, publish `public` | legacy Workforce Intelligence app at `/`, plus the console at `/console-live.html` |

Because both sites share this one repo, the new site **must** set base directory
`operational` so Netlify reads `operational/netlify.toml` instead of the root
one (which publishes `public/`). One-time repo-link is done in the Netlify UI:
Project → Build & deploy → link to `rkp-ops/steadymd-workforce`, branch `main`,
base directory `operational`, build command empty.

## Deploy checklist (front end)

1. If the template changed, rebuild: `python platform/web/build_live.py`
   (reads `platform/web/console.tpl.html` → writes **both**
   `public/console-live.html` and `operational/index.html`).
2. Commit and push to `main` (open a PR; merge it).
3. Both Netlify sites redeploy automatically on the push — no upload.
