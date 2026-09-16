# Plan 045: The day — a personal planning list

> Executor: this plan is **not ready to execute**. The decisions below are
> settled with the maintainer; the questions under "Still open" are not, and
> each one changes what gets built. Close them first, then write the steps.

## Status

- **Priority**: P2 / **Effort**: M / **Risk**: MEDIUM (new surface, touches
  many modules' screens) / **Depends on**: 034 (home queue), 043
  (notifications)
- **Category**: product. Raised by the maintainer on 2026-09-16 and shaped in
  conversation the same day; parked here rather than built.

## What it is

A person's own day: a short list of what they mean to get through, which they
write themselves, plus the work they picked up as they went. Unfinished items
roll to tomorrow, and tomorrow already holds what is scheduled — interviews,
tasks that fall due. They may share their day with named colleagues.

## What it is not

**It is not a record of what someone did.** Auto-capture is opt-out: a
checkbox on the screen where the work happens, checked by default, that the
person may clear. A list with holes in it cannot be an account of a day, and
must never be presented as one.

That matters because the app already has the reliable version:
`activity_log` records who did what and when, unfalsifiably, and the company
Activity tab (plan 030) reads it. If oversight is ever the goal, the work is
a better view over `activity_log` — not this feature.

## Decisions taken (2026-09-16, with the maintainer)

| Question | Decision | Why |
| --- | --- | --- |
| Whose tool? | Mostly a planning tool | The opt-out checkbox is then legitimate; no claim is made that the list is complete |
| What happens when the real work finishes elsewhere? | The item follows the record and stops appearing | A copy goes stale, lingers, and rolls to tomorrow forever until tidied by hand |
| Who sees someone's day? | The person picks, per viewer | Their tool, their choice — not their manager's by default |
| Who has a day at all? | A new `day.use` capability | Granted through the access editor like everything else; HR and recruiters first, wider later, with no code change |

## Shape

Store only what is genuinely the person's; derive the rest at read time. This
is how `dashboard_snapshot` (044) and the Home queue (034) already work.

- **`day_items`** — the person's own rows: a free-written line, or a pointer
  to a record they picked up (`entity_type` + `entity_id`). Carries the day it
  belongs to, an order, an optional note, and — for free-written items only —
  a done flag. Pointers hold no status of their own.
- **`day_shares`** — who may read my day: `(owner_person_id, viewer_person_id,
  granted_at)`, revocable. RLS reads my own day always, and another's only
  through a row here.
- **`my_day(p_person_id, p_date)`** → jsonb, one call, the way
  `dashboard_snapshot` does it: my items for the day, each pointer resolved to
  its current title and status; unfinished items carried from earlier days;
  what is scheduled for that date (interviews, tasks due); and the Home queue
  rows that are already computed for the viewer. Refuses unless the caller is
  the owner or holds a share.
- **Capture** happens in the client, from the screen where the work happens:
  the checkbox decides whether `add_day_item` is called at all. Nothing is
  written and then retracted — which is what makes the opt-out honest.

## Why not the alternatives

- **Triggers writing a materialised day.** Reads get simpler, but it couples
  the feature into every module's triggers, and the checkbox stops working:
  the trigger has already fired by the time the client says "not this one".
  Snapshot titles also drift when the underlying record is renamed.
- **Extending `plan_tasks`.** It hangs off `plans` with
  `employment_period_id`, phases and templates. Personal items have none of
  those, and bending it would distort a table onboarding and offboarding
  depend on.

## Still open — close these before writing the steps

1. **Which actions offer capture.** "Start a screening", "start onboarding",
   "open a hiring request" were named; the full list is not decided, and each
   one is a screen to touch.
2. **What "done" means for a pointer** whose record has no terminal state
   (a candidate sits at a stage for weeks). Without an answer these never
   leave the day.
3. **Carry-over mechanics**: a nightly job that moves the day forward, or a
   "carried over" band computed at read time. The second needs no cron and
   cannot run twice, so it is probably right — but it changes what `day` on a
   row means.
4. **Prioritising**: the maintainer said "we can prioritise them or not".
   Ordering is cheap (a sort key); priority levels are a new vocabulary.
5. **What lands in tomorrow automatically** beyond scheduled interviews —
   tasks due, leave starting, payroll dates? Each is another resolver.
6. **Where the day lives**: a page of its own, or a panel on My workspace,
   which already carries tasks, requests and policies.
7. **Notifications overlap** (043): a notification and a day item may say the
   same thing twice.

## Tests (sketch, to be firmed up with the steps)

- smoke: a person without `day.use` gets nothing; a share is required to read
  another's day and revoking it closes the door; a pointer whose record is
  finished drops out of the day; free-written items are unaffected.
- unit: the day's assembly rules — carry-over, ordering, which sections a
  viewer sees.
- E2E: write an item, pick up work with the checkbox on and off, finish that
  work elsewhere and watch the item leave the day, share with a colleague and
  have them read it.
