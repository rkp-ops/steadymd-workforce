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

## Why manual steps happen here

- **Git push is blocked.** Both `git push` (org egress policy → 403) and the
  GitHub API integration (read-only → 403 on ref writes) are denied, so I can't
  push branches or open PRs. The repo's entire history is manual "Add files via
  upload" through GitHub's web UI. So the pattern is: I produce the files and
  hand them over with paths + commit text; the user uploads them.
- **Netlify serves `public/`.** The live console is `public/console-live.html`
  (publish dir = `public`, see `netlify.toml`). To deploy the front end the user
  replaces that one file. A file uploaded anywhere else (e.g. the repo root) is
  not served.
- **The database I can change directly.** Supabase schema and data go through
  the Supabase tooling and take effect live — not manual steps, no upload.

## Deploy checklist (front end)

1. If the template changed, rebuild: `python platform/web/build_live.py`
   (reads `platform/web/console.tpl.html` → writes `public/console-live.html`).
2. Hand over `public/console-live.html`: upload into the `public/` folder,
   replacing the existing file.
3. Netlify redeploys automatically once it's committed.
