# Plan 033: Rehire, and equipment on the offboarding checklist

> Executor: follow step by step, verify every gate, touch only in-scope files,
> STOP instead of improvising on drift. Reviewer maintains plans/README.md.

## Status

- **Priority**: P2 / **Effort**: S / **Risk**: LOW / **Depends on**: main (post-032, `f5cfa0d`)
- **Category**: feature (blueprint "rehire"; "equipment on offboarding
  checklists" — nothing leaves with the leaver)

## Migration 0025

- `plan_tasks.asset_id` (nullable) links a checklist task to an asset.
- `app.add_equipment_tasks(p_plan_id)`: one critical IT task per open
  assignment (reserved or issued) of the plan's person in the plan's
  company — "Return {tag} · {type} {model}" in the last-day phase, due on
  the last working day. `schedule_departure` calls it after creating the
  plan (body otherwise unchanged); re-scheduling adds tasks for assets
  handed out since.
- `return_asset` / `cancel_reservation` mark the matching open task done
  (done_by = the person who took it back), so the checklist reflects the
  handover without a second click.

## App

- Person profile: **Add employment** for admins and `employment.edit`
  holders (companies limited to where they may edit); when the person's
  latest period is former the button reads **Rehire** and the form
  pre-fills the last job title and type.

Tests: smoke (tasks created for held assets only, done on return, none
for people without equipment, re-schedule adds new ones), E2E
`rehire-equipment.spec.ts` (issued laptop → schedule departure → plan
shows the return task → return on the Equipment tab → task done → mark
former → Rehire → new active period).
