---
name: backup
description: >
  Snapshot the project and its Vault docs repo onto a `backup` branch in each, then return
  both to the branch that was checked out before. Trigger when the user says "сделай бэкап",
  "backup", "забэкапь проект", "снапшот на backup", or asks to back up the project / docs before
  a risky change. Merges current → `backup` (conflicts resolve to current), pushes `backup` to
  origin, restores the original branch. Hard-stops if either working tree is dirty.
---

# Project backup — current branch → `backup`, both repos

Two repos:

- **Project repo** — `git rev-parse --show-toplevel` from the working directory (do not hardcode).
- **Vault docs repo** — `C:/Users/PC/Documents/Personal Vault/Tank Props Docs` (confirmed git repo).

Do everything with `git -C <repo> …` so the working directory never has to change.

## Phase 1 — validate BOTH repos before mutating either

For each of the two repos, in this order, and **abort the whole skill on the first failure**
(report what failed, make no changes anywhere):

1. Repo exists and is a git repo: `git -C "<repo>" rev-parse --git-dir`. If the Vault path is
   missing or not a git repo → report it, then continue with the **project repo only**; do not
   fail the project backup for a broken Vault. (A missing project repo is a hard stop.)
2. Record the current branch: `git -C "<repo>" symbolic-ref --quiet --short HEAD`.
   - Empty result = detached HEAD → **stop**, report (cannot return to a prior branch).
   - Current branch is already `backup` → **stop**, report (nothing sane to snapshot).
3. Working tree clean: `git -C "<repo>" status --porcelain`.
   - **Any output → STOP the entire skill.** Do not stash, do not commit, do not touch `backup`.
     Show `git -C "<repo>" status` for the dirty repo(s), say which repo(s) are dirty, and ask the
     user to commit or discard, then re-run. This is a hard gate (the user chose "stop and ask").

Only if every check passes for every in-scope repo, proceed.

## Phase 2 — back up the project repo

Let `CUR` = its current branch (from Phase 1).

1. If `backup` does not exist: `git -C "<repo>" branch backup "<CUR>"`.
2. `git -C "<repo>" checkout backup`
3. `git -C "<repo>" merge -X theirs --no-ff "<CUR>" -m "backup: <CUR> @ $(git -C "<repo>" rev-parse --short "<CUR>") $(date +%Y-%m-%d)"`
   - `--no-ff` → a merge commit every time, so `backup` history is a list of backup points.
   - `-X theirs` → any conflict resolves to `CUR`'s content.
   - "Already up to date" (backup identical to CUR) is a normal, successful no-op.
   - Any non-conflict merge failure → `git -C "<repo>" merge --abort`, `git -C "<repo>" checkout
     "<CUR>"`, report, stop.
4. Push, only if an `origin` remote with a URL exists (`git -C "<repo>" remote get-url origin`):
   - `git -C "<repo>" push origin backup`
   - If rejected as non-fast-forward: `git -C "<repo>" push --force-with-lease origin backup`
   - No `origin` → skip, note "backup not pushed (no origin remote)".
5. `git -C "<repo>" checkout "<CUR>"` — back to the original branch.

## Phase 3 — back up the Vault docs repo

Same five steps as Phase 2, with the Vault repo and its own `CUR`. Skip this phase entirely if
Phase 1 marked the Vault out of scope (missing / not a git repo) — and say so in the report.

If Phase 3 fails after Phase 2 succeeded: still attempt `git -C "<vault>" checkout "<vault CUR>"`
so the Vault is left on its original branch, then report both repos' exact state.

## Phase 4 — report

One compact block per repo:

```
<repo name>: backup ← <CUR> (<merge result>); pushed: yes/no/skipped; back on <CUR>, tree clean
```

Then a one-line overall: both repos snapshotted and restored, or exactly what is left half-done.

## Notes

- Never runs on a dirty tree — the Phase 1 gate is absolute.
- `backup` only ever moves forward (merge `--no-ff` into it); a normal `push origin backup`
  fast-forwards the remote. `--force-with-lease` is the fallback only if someone rewound remote
  `backup`.
- This skill does not create backups of uncommitted work by design — commit first.
- The skill file lives on `main`; it rides into `backup` with every snapshot, which is fine.
