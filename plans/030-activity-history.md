# Plan 030: Activity history — the audit trail, readable

> Executor: follow step by step, verify every gate, touch only in-scope files,
> STOP instead of improvising on drift. Reviewer maintains plans/README.md.

## Status

- **Priority**: P2 / **Effort**: S / **Risk**: LOW / **Depends on**: main (post-029, `c399389`)
- **Category**: feature (blueprint "Administration: audit history —
  configure, preview, save, revoke, troubleshoot"; data-model §0005 audit)

## No migration

`activity_log` (0005) with its read policies (0006: admins and
`access.manage` per company; 0012: recruitment entities for `jobs.view` /
`candidates.view`) and the redaction of 0018/0020 are enough. Actor names
come from `people` (readable per directory rules).

## App

- `lib/activity.ts`: `ENTITY_LABELS`, `actionLabel`, `summarizeChange
  (before, after)` — the fields that differ (insert: the notable fields
  set; update: `field: old → new`; delete: the identity), skipping
  timestamps / ids / json blobs, values truncated; unit tests.
- Company profile **Activity** tab — shown when the viewer is an admin or
  holds `access.manage`, `jobs.view` or `candidates.view` in the company
  (RLS trims what each sees): the last 200 entries with filters by entity
  type and a free-text match on the summary; each row: when, who (or
  "system"), entity, action, summary.

Tests: unit; E2E `activity.spec.ts` (an immediate employment change made
in the UI shows on the Activity tab with the admin as actor and
"Job title: … → …" in the summary; the entity filter narrows the list).
