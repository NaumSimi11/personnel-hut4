# Plan 029: Equipment & IT — asset register, assignments, IT requests

> Executor: follow step by step, verify every gate, touch only in-scope files,
> STOP instead of improvising on drift. Reviewer maintains plans/README.md.

## Status

- **Priority**: P1 / **Effort**: M / **Risk**: LOW / **Depends on**: main (post-028, `a1b4aa3`)
- **Category**: feature (blueprint "Equipment & IT: assets, assignments,
  requests — reserve, issue, return, set up access, confirm completion")

## Migration 0022

- Assets stay a plain register (RLS 0006: `it.view` reads, `it.assign`
  writes); a trigger trims/upper-cases the tag and keeps `status` in sync
  with assignments — the client never writes an asset's status.
- Assignments move only through functions: `reserve_asset(p_asset_id,
  p_person_id, p_note)` (`it.assign`; asset available; person employed in
  the asset's company; one open assignment per asset) → asset `reserved`;
  `issue_asset(p_assignment_id)` (`it.assign` or `it.complete`) → `assigned`,
  `issued_at`/`issued_by`; `return_asset(p_assignment_id, p_condition,
  p_status available|damaged|lost|retired)` → `returned_at` and the asset's
  next status; `cancel_reservation(p_assignment_id)` → asset `available`.
- IT requests: insert pins `status = 'open'`, `requested_by` = signed-in
  person, checks the person's employment in the company; `advance_it_request
  (p_request_id, p_status, p_assignee_id, p_blocked_reason)` — `it.assign`
  assigns and moves open ↔ in_progress ↔ blocked (reason required), cancels;
  `it.complete` (or `it.assign`) marks done. Assets, assignments and IT
  requests are audited.

## App

- `lib/equipment.ts`: asset form schema, status labels, assignment /
  request action mirrors; unit tests.
- Company profile **Equipment** tab (`it.view`): asset register with add
  form (tag, type, model, serial, location, note), per-asset Reserve for a
  person → Issue → Return (condition + next status); IT requests list with
  create (person, title, systems, due), assign, status moves.
- Person profile **Equipment** card: held / reserved assets and open IT
  requests (viewer: self or `it.view`); My workspace **My equipment**.

Tests: smoke (status sync, one open assignment, employment check,
capability gates, request pinning and transitions), unit, E2E
`equipment.spec.ts` (add asset → reserve → issue → shows on profile →
return damaged → status; IT request open → in progress → done).

Out: equipment on onboarding/offboarding checklists (a later slice links
`it_requests.plan_task_id`), asset custom fields.
