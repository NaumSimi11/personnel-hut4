# 060 — A candidate on another position, and the way back (migration 0074)

task.md: *"ook, so we need to be bale to add an existing cancidate to another
possiotion ( transver possition to opening or not openings )"* — and, asked
what that needs: *"yes but we need to be able to view them too, and to revert
them."*

## Three parts, of which one already existed

**Viewing** was there: the candidate record already lists every application
with its job, company, stage, date and source. What it did not say was the
*job's* status, so a row against a draft or closed job read like any other.
It says so now.

**Attaching to something that is not an opening** was an app-side limit, not a
database one. `app.open_application` (0067) has always accepted `draft`,
`ready`, `open` and `on_hold`, and refuses only `filled` and `closed`. The
dialog offered `ready / open / on_hold`, so a draft job — one being written,
with no listing yet, which is a perfectly ordinary place to park somebody —
was invisible. It is offered now, and every option that is not `open` says
which status it is.

Filled and closed jobs stay out of the picker. They are refused by the
database, and listing every job the holding has ever closed would put a few
hundred unusable rows in a dropdown to teach one sentence; the sentence is
under the heading instead.

**Reverting** did not exist at all, and is the substance of this slice.

## Why an undo is not a withdrawal

Withdrawing says the person stepped away. Rejecting says somebody decided.
Attaching the wrong candidate to the wrong job is neither — it is a two-click
mistake — and recording it as a withdrawal leaves a sentence on their record
and in the job's history that is simply untrue.

So `detach_candidate_from_job` deletes the application, and may do so only
while the application is still **nothing but an attachment**:

- not imported (`source_provider is null`) — an import is not somebody's
  mistake, and re-running it would put the row straight back;
- nobody hired from it;
- nobody carrying it: no `owner_id`, no `next_action`. Being given an
  application emails the assignee (0034's `t9_notify`) and writes **no**
  `application_events` row, so without this check a "Take back" would delete
  somebody's queue item under them and leave a notification pointing at
  nothing;
- still at `new`;
- no events, interviews, offers or files.

Those checks are spelled out rather than left to the foreign keys, because the
keys would not save anybody: `application_events`, `application_files`,
`interviews` and `scorecards` all CASCADE. A careless delete would take a
panel's interview feedback with it, and only an offer would raise a word of
protest. The smoke block proves each one, and that the CV and the interview
are still there afterwards.

Once anything has happened, the row is history and the refusal says what to do
instead.

## What it touches on live

After applying 0074: **0 of 4,157 applications are detachable.** Every one is
imported, or has moved on, or has something recorded against it. The undo
protects mistakes made from here on and cannot reach anything that already
exists.

## One consequence worth knowing

A reviewer sees a holding-wide candidate *through* an application in their
company (0067). Take the last one back and the candidate leaves their sight
with it — the visibility rule working, not the undo overreaching. The card
reloads the record afterwards rather than assuming it is still there, and the
smoke block asserts the pool record itself is untouched.

## Files

`supabase/migrations/0074_detach_candidate.sql`, `app/src/lib/detachApplication.ts`
(+ tests), `CandidatePage.vue` (job status, Take back), `SourceToJobDialog.vue`
(draft jobs, status in the label).
