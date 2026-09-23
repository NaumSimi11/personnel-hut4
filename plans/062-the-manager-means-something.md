# 062 — The manager, from a label into a person (migrations 0077–0079)

The maintainer, after plan 061 shipped with its manager path unreachable:
*"ok so the manager , we can do what?"* — and, given the options, chose to
make it mean something.

## What was actually wrong

Not one feature. On live, before this:

| | |
|---|---|
| Employments naming a manager | **0** |
| Plan tasks with an owner (`owner_id`) | **0 of 42** |
| A manager opening a plan page | refused (`plans`: self or `tasks.view`) |

0040 seeds four checklist lines with `default_owner_role = 'manager'` — Team
introduction, First 1:1, Handover documented and accepted, Manager sign-off.
`plan_tasks` has always let a task's owner read their own row. My workspace
has always listed tasks by `owner_id`. **Both ends were built and nothing
joined them**, so those four lines could never reach anybody — and the "My
tasks" card has been empty for every person since the day it shipped.

## What it does

- `app.owner_for_role(plan, role)` turns a line's role into a person: `hr` →
  whoever started the plan, `employee` → the person themselves, `manager` →
  the manager on their employment, `it` → the company's `it_owner`. `finance`
  stays null — an unassigned line is honest where a wrong one is not.
- Every writer of `plan_tasks` uses it: `copy_template_tasks`, `add_plan_task`
  and `add_equipment_tasks` (the last two were missed first time round, so
  every future departure would have re-created unowned critical lines).
- A backfill for the plans already running. **On live it filled 22 of 42**:
  all 19 HR lines and all 3 employee lines. The 12 IT and 8 manager lines
  stayed empty, because no `it_owner` is configured and no employment names a
  manager — which is the data entry nobody can skip.
- `plans` is readable by the manager named on its employment, and by anybody
  who owns a line in it. `plan_tasks` follows, in full: a checklist read in
  part is worse than one not read at all, because the page decides whether the
  critical work is finished by counting what it was given.

## The one this created, and had to pay for

The backfill woke a branch of the `plan_tasks` write policy that had never
been reachable while `owner_id` was always null: `app.is_self(owner_id)`
grants **ALL**. So a person with no capability anywhere could delete their own
checklist line, tick a line that requires evidence without filing any, or move
the row into somebody else's plan — the `WITH CHECK` only ever looked at
`owner_id`.

Harmless while nobody owned anything. Filling the owners is what made it
dangerous, so 0079 removes the branch and gives ticking its own door:
`complete_my_plan_task`, which touches three columns, refuses a line that
still needs its document, and refuses a blocked one. The app's two tick paths
now go through it — which also closes a hole that predates all of this: a
`tasks.complete` holder could tick a `requires_evidence` line with no evidence
at all.

## The pattern that keeps biting

Three times in one day a policy helper was revoked from `public` and broke the
database: `app.on_task` (0072), `app.can_view_access` (0075), and
`app.owns_plan_line` here. A function named in a `using` clause is not an
internal. It is written down in 0079 where the next person will see it.

## Also, 0078

`application_sub_statuses` and `candidate_sources` carried `admin_write`
policies and only ever granted SELECT — so the Labels panel's rename, the
feature the maintainer asked for, would fail on any database that does not
hand out DML by default. It works on live only because Supabase does. Now
explicit.

## What still needs a person

Record the managers (the employee record's corrections edit `manager_id`), and
set an `it_owner` per company under Settings. Until then this changes nothing
— which is why it was safe to apply first.
