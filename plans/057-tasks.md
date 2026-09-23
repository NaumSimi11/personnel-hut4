# 057 — Tasks that stand on their own (migration 0072)

task.md: *"my tasks - how cna we use them - i want to add task to myself,
connect some 1 to my task, and the higher profiles can assign tasks to me."*

## What "My tasks" means today

Nothing but checklist lines. `MyWorkspacePage` and `HomePage` both read open
`plan_tasks` rows whose `owner_id` is you — lines from somebody's onboarding
or offboarding plan. There is no table for a task that is simply a thing you
have to do, so all three of the maintainer's sentences are impossible: you
cannot write one down, you cannot put a colleague on one, and your manager
cannot hand you one.

The capabilities already exist and already sit in the right presets —
`tasks.assign` and `tasks.complete` are held by Company HR and Holding HR —
and `employment_periods.manager_id` names a manager. Both halves of "higher
profiles" are therefore already in the database; only the task is missing.

## Decisions (the maintainer, 2026-09-23)

- **Assigning:** `tasks.assign` in the person's company, or the manager named
  on their employment. Nobody else may put work on your list.
- **Connecting:** the colleague can *work* it — they see it, they are told,
  and either of you can tick it — while it stays yours to change or delete.
- **Visibility:** the people on it and nobody else. Not HR, not a platform
  admin. This is a working tool, not a monitoring one.

Two consequences follow from that third one and are worth stating, because
they shape the code:

1. **Reading goes through an RPC.** A plain employee may read only their own
   row in `people` (0006), so a task carrying `person_id`s would render as a
   list of uuids. `my_tasks()` returns the names of the people already on each
   task — nobody else's.
2. **Connecting needs a door of its own.** For the same reason a plain
   employee cannot see a colleague to pick. `app.may_connect_task` allows
   anyone you may already view **plus** anyone actively employed in a company
   where you are actively employed. That is a real widening and it is
   deliberate: it exposes a colleague's name, through one purpose-built
   function, to somebody who works beside them. The directory still shows
   them nothing — 0036's rule is untouched everywhere else.

## 1. Migration `supabase/migrations/0072_tasks.sql`

- `tasks` — `person_id` (whose list), `company_id` (from their active
  employment, for the notification), `title`, `detail`, `due_date`, `status`
  (`open` / `done`), `created_by`, `done_by`, `done_at`. Length CHECKs on the
  text, and `(status = 'done') = (done_at is not null)` so the state and the
  stamp cannot drift apart.
- `task_people` — `(task_id, person_id)`, `added_by`, `added_at`. Membership
  is the whole row: on it means see it, told about it, may tick it.
- Helpers: `app.task_company`, `app.may_assign_task`, `app.may_connect_task`,
  `app.on_task`, `app.may_edit_task`.
- RLS: select through `app.on_task`; **no client write policy at all** — every
  change goes through the functions, so the rules live in one place.
- `save_task(p jsonb)` — insert or update, with `with_ids` replacing the
  connected list when present and left alone when absent (so editing a title
  never quietly drops a colleague). Refuses a blank title, a task changing
  hands, and connecting the owner to their own task. Notifies the person when
  somebody else sets them a task, and each *newly* connected colleague.
- `set_task_done(p_task_id, p_done)` — anybody on the task; unticking clears
  the stamp; the owner is told when somebody else finished it.
- `delete_task(p_task_id)` — the owner or whoever set it.
- `my_tasks()` — `{mine, set_by_me}` with names.
- `task_candidates()` — `{assignable, connectable}`, exactly what the write
  functions will accept, so the dialog never offers what the door refuses.
- Grants: `select` on both tables (writes are the functions'), execute on the
  five public functions. `app.on_task` stays executable — the row policies
  ask it.

## 2. Smoke — `supabase/tests/smoke.sql`

A `0072` block with **fixtures of its own**: earlier blocks end both Omar's
and Fiona's Company A employment, and every rule here turns on being actively
employed beside somebody. Tomo and Tina are two plain Company A employees with
no grants; Alex (Director, and no `tasks.assign`) is Tomo's manager; Bea is HR
in Company B only; Ada is the platform admin.

1. Tomo writes one for himself: trimmed title, his, open, his company; it is
   on his list and he has handed nothing out; a blank title is refused.
2. He cannot put one on Tina's list — the refusal names her.
3. He connects her instead: one row, told once; saving the same list again
   tells nobody twice; a title edit does not drop her; connecting the owner,
   and changing hands, are both refused.
4. `task_candidates()` for him: only himself to assign to, Tina connectable
   although he may not *view* her, Bea (Company B) not.
5. Tina sees it as his, may not rewrite or delete it, ticks it off, and
   unticking clears the whole stamp.
6. Alex (manager) hands Tomo one, and it shows under what he set, not under
   what he has to do. Bea, HR in another company, is refused.
7. Ada the admin sees no task, no membership row, none of her own.
8. Tomo deletes his, the connections go with it, and a second delete says so.
9. The three notifications, **checked outside any role** — a notification is
   readable only by the person it is for, so no role above could have checked
   somebody else's.

`bash supabase/tests/local-verify.sh` ends `SMOKE TESTS PASSED` (72
migrations).

## 3. App

- `app/src/lib/tasks.ts` — the zod input mirroring the database's limits,
  `taskPayload` (a cleared note and date go as null, not `""`), `readMyTasks`
  (the RPC's JSON is never assumed), `dueTone` / `dueLabel` (overdue, today,
  soon = the week ahead), `orderTasks` (open first, nearest date, undated
  after dated, done last), `ownerLine`, `withLine`.
- `components/tasks/TaskDialog.vue` — task, due, note, "For" (only when there
  is somebody else to hand one to) and the "With" chips.
- `components/tasks/MyTasksCard.vue` — the list with tick, Change, Delete,
  Show done, and "Waiting on other people" for what you handed out.
- Mounted on **My workspace** and on **Home**, above the checklist card, which
  is renamed *Checklist tasks* — what it always actually was.

## 4. Tests

`npx vitest run`, `npx vue-tsc --noEmit`, and `app/e2e/tasks.spec.ts` (write
one down → refuse a blank title → change it and connect a colleague → tick →
show done → delete), which seeds nothing and cleans by title.

## 5. Apply live

The maintainer applies 0072 before the app is deployed; the E2E runs after.

## 6. Docs

`plans/README.md`, `docs/development-plan.md`, `docs/data-model.md`,
`docs/session-handoff.yaml`.
