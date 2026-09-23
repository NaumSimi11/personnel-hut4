# 056 — Closing job openings (migration 0071)

task.md: *"i dont know why do we have that much open positions ffs … they will
resolve them by hand, just to have a way of closing them (abandon) and deleting
if needed."*

## What is wrong today

The Zoho import brought 75 jobs across the holding, most of them `open` or
`ready` years after anybody stopped working them, each dragging its old
applicants behind it. Three things are missing for the sweep:

1. **Closing is one job at a time, from inside the job.** `jobStatusActions`
   offers "Close job" on the job page only. To close thirty, HR opens thirty
   pages. The Job openings list — the one place where they are all visible —
   offers nothing but "Open job".
2. **Closing leaves the candidates in play.** `jobs.status = 'closed'` says
   nothing about the applications: they stay at `new` / `screening` /
   `interview`, so "In play" keeps counting them, the Applicants tab keeps
   listing them and the pipeline keeps reporting them. A closed job with 14
   people still waiting for an answer is exactly the lie the sweep is meant to
   end. *Abandoning* an opening means closing it **and** withdrawing whoever is
   still in play, with a reason that lands on each application and its timeline.
3. **Nothing says who closed it, when, or why.** A row reading "Closed" with no
   author is unauditable, and reopening leaves no trace either.

Deleting already works (`a8df79c`) but only from the company page, and only for
a job nobody ever applied to — that rule stays; it is the database's.

## Decisions

- **Close and abandon are one action with a switch**, not two verbs. The dialog
  closes the opening; the checkbox — pre-ticked when anybody is in play — also
  withdraws them. Reason required whenever candidates are withdrawn (it is
  written onto their record), optional for a plain close.
- **Withdrawn, not rejected.** Nobody judged these people; the opening went
  away. `withdrawn_reason` and a `stage_change` event carry the sentence.
- **`filled` may be closed too** (the job page already offers it); a job already
  `closed` is counted as `already_closed` and left alone, so re-running a
  selection is harmless.
- **All-or-nothing per call**, like `log_outreach`: one refusal rolls back the
  lot, and the message names the company and the job that refused.
- **Capabilities:** `jobs.edit` in the job's company to close it, and
  additionally `candidates.review` to withdraw its applicants — exactly what the
  RLS policies on `jobs` and `applications` already demand of the same writes by
  hand.
- **Reopening clears the closing stamp.** A trigger, so the plain status update
  on the job page is covered without touching that code.
- **Withdrawing is not undone by reopening.** Those candidates were told. If a
  reopened job wants them back, that is a new application — the talent pool
  (0067) is how they come back.

## 1. Migration `supabase/migrations/0071_close_jobs.sql`

- `alter table public.jobs add column closed_at timestamptz, closed_by uuid
  references public.people(id), closed_reason text`.
- `app.jobs_closing_stamp()` — `before insert or update on public.jobs`
  (insert too, or a job born closed keeps a status its columns contradict;
  `OLD` is unassigned there, so the arrival is tested with `tg_op`):
  - status becomes `closed`: `closed_at := coalesce(new.closed_at, now())`,
    `closed_by := coalesce(new.closed_by, app.current_person_id())`, the reason
    left as given (so `close_jobs` may set it and the plain update may not).
  - status leaves `closed`: all three back to null.
  - status stays `closed`: untouched.
- `public.close_jobs(p_job_ids uuid[], p_reason text, p_withdraw boolean)
  returns jsonb` — `security definer`, `set search_path = public`, in the
  `log_outreach` shape: signed in, at least one id, reason ≤ 2,000 chars,
  reason ≥ 5 chars when `p_withdraw`, ids deduped, per job the two capability
  checks, then the close and (when asked) `insert into application_events
  (kind 'stage_change', from the current stage, to 'withdrawn', body = reason)`
  followed by the `update … set stage_key = 'withdrawn', withdrawn_reason`
  for every application **not** already `hired` / `rejected` / `withdrawn`.
  Returns `{closed, already_closed, withdrawn}`.
- Grants: revoke from `public, anon`, execute to `authenticated`.
- `app/src/types/database.ts`: the three `jobs` columns and the `close_jobs`
  function entry, by hand as the file demands.

## 2. Smoke — `supabase/tests/smoke.sql`

A `0071` block before the final `select`, on its own fixtures: three Company B
jobs and one Company A job, with five applications on the first B job covering
`new`, `screening`, `interview`, `hired` and `rejected`. Bea (the Company HR
preset, in Company B only) does the work; Omar (no grants) and Company A are
where it stops.

1. A close with no withdraw: status `closed`, `closed_at` and `closed_by`
   stamped with Bea, no reason kept, the applications untouched.
2. An abandon: `{closed: 1, already_closed: 0, withdrawn: 3}` — the hired and
   the rejected rows keep their stage and their own reasons; the three others
   are `withdrawn` with the reason on the row, one `stage_change` event each
   carrying the true `from_stage_key` and Bea as the actor, and no sub-status
   (0069's rule).
3. The same call again, with the id twice: `already_closed` counts it,
   `withdrawn` is 0, and neither the date nor the reason is overwritten.
4. Reopening through a plain update clears all three columns and leaves the
   withdrawn withdrawn; closing again re-stamps, proving the trigger and not
   the RPC is what guarantees it.
5. A job inserted as `closed` is stamped on insert too, and leaving `closed`
   clears it whichever way the row arrived.
6. Refusals: an empty array, an unknown id, `p_withdraw` with a blank reason
   (and the job it named still open), and Omar, who holds nothing.
7. A selection spanning Company B and Company A: refused by capability, the
   message naming Company A, and **both** jobs still open — read back outside
   Bea's role, since the Company A row is not hers to see.

`bash supabase/tests/local-verify.sh` must end `SMOKE TESTS PASSED` (71
migrations).

## 3. App

- `app/src/lib/closeJobs.ts` (new): `closeSelection(rows)` → how many will
  close, how many are closed already, how many candidates are in play, and
  whether withdrawing may be offered at all (`close_jobs` demands
  `candidates.review` in *every* company of the call, so one company the
  viewer cannot review in takes the option away rather than losing them the
  close as well — the dialog names it); `closeQuestion` / `closeSummary` → the
  sentences before and after; `friendlyCloseError(message)` in the
  `friendlyJobsError` style. Unit tests beside it.
- `app/src/components/hiring/CloseJobsDialog.vue` (new): the count, the reason
  textarea, the "also withdraw the N candidates still in play" checkbox (absent
  when nobody is in play, and replaced by a line naming the company when the
  viewer may close there but not move candidates), the refusal line. Built like `RejectApplicationDialog`
  (native `<dialog>`, `open()` exposed, one `confirmed` event).
- `app/src/components/hiring/JobOpeningsPanel.vue`: a select column (header
  checkbox selects the filtered rows), a "Close selected" button in the card
  head, per-row **Delete** reusing `jobDeletable` / `friendlyDeleteError` from
  `lib/hiringDelete.ts` behind `useDialogStore().confirmAction`, and a
  `Closed by … · reason` line under the status of a closed row. The total per
  job comes from PostgREST's embedded `applications(count)` rather than a
  second page of rows — and because that count is read under the viewer's own
  RLS, `jobDeletable` gains a `countVisible` argument: without
  `candidates.view` here every job would report zero and the button would
  promise that nothing was ever received. The company page has carried the
  same defect since `a8df79c` and takes the fix with it. Selection is cleared
  by a filter change (the rows behind it change) and after a successful
  close.
- Rows the viewer cannot edit are not selectable, with the reason in the
  checkbox's `title` — the same teaching pattern as the disabled Delete.

## 4. Tests

- `npx vitest run` (the new lib tests) and `npx vue-tsc --noEmit`.
- `app/e2e/close-openings.spec.ts`: seed a company, a job, three applications;
  sign in as the admin; select the row, close it with withdraw ticked; assert
  the status badge, the "In play" column at 0, and the applications withdrawn;
  then delete a second job that has no applications. Cleans up after itself.

## 5. Apply live

The maintainer applies 0071, then the E2E runs.

## 6. Docs

`plans/README.md` row, `docs/development-plan.md` Done row,
`docs/data-model.md` for the three columns and the function,
`docs/session-handoff.yaml` state + next.
