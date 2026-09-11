# Plan 018b: Interviews, blind scorecards, offer builder

> Executor: follow step by step, verify every gate, touch only in-scope files,
> STOP instead of improvising on drift. Reviewer maintains plans/README.md.

## Status

- **Priority**: P1 / **Effort**: L / **Risk**: MEDIUM / **Depends on**: main (post-018a, `294d89d`)
- **Category**: feature (blueprint §4 Review / Interviews & Offer; core plan
  §9 interview feedback distinct from performance reviews)

## Why this matters

Structured evaluation is what separates a defensible hiring decision from a
vibe. Each interview produces a scorecard against the job's criteria — a
1–4 rating with evidence per criterion and an overall recommendation —
submitted blind: an interviewer cannot read colleagues' scorecards for that
interview until their own is in. The offer is built from explicit terms,
approved by someone other than its author (`offer.approve`), extended, and
its acceptance feeds Confirm hire with the agreed start date.

## Decisions (maintainer, 2026-09-11)

- Anyone with `candidates.review` may submit a scorecard; the panel list is
  information (who was scheduled), not a gate.
- Blind rule (RLS): a scorecard is visible to its author; to anyone with
  `candidates.view` who is not on that interview's panel; and to panel
  members once they have submitted their own for that interview. Admins on
  a panel are blind like everyone else — it is a process rule, not an
  authorization one.
- Ratings 1–4 (no middle), recommendation strong_no / no / yes / strong_yes.
- Criteria live on the job (`jobs.scorecard_criteria`), default set when
  empty; each scorecard snapshots the criterion labels it rated.

## Migration 0014

- `jobs.scorecard_criteria jsonb not null default '[]'` (array check).
- `interviews` (application_id, company_id derived, kind, scheduled_at,
  duration_minutes, location, notes, status scheduled|completed|cancelled,
  created_by). RLS: read candidates.view, write candidates.review. Audited.
- `interview_panel` (interview_id, person_id) pk pair. RLS via interview.
- `scorecards` (interview_id, application_id + company_id derived,
  author_id = current person enforced, ratings jsonb, recommendation,
  summary, submitted_at; unique (interview_id, author_id)). RLS: insert /
  update own with candidates.review; select per the blind rule using
  `app.is_on_panel(interview)` and `app.has_scored(interview)`.
- `offers`: add `created_by`, `decline_reason`; replace the write policy
  with insert (candidates.review) + update of terms while draft
  (candidates.review); status moves only via `advance_offer(p_offer_id,
  p_to_status, p_reason)`:
  draft → in_approval (candidates.review) · in_approval → approved
  (offer.approve, not created_by) · in_approval → draft (offer.approve,
  send back) · approved → extended (candidates.review) · extended →
  accepted | declined (candidates.review; declined needs a reason) · any
  non-terminal → withdrawn (candidates.review). accepted sets accepted_at.

## Scope

In: migration + smoke tests; `lib/interviews.ts`, `lib/offers.ts` with unit
tests; candidate page cards (Interviews with scorecards; Offer builder);
job tab "Interviews & Offer" (upcoming interviews, offers by candidate);
scorecard criteria editor on the job's Description tab; Confirm hire
prefilled from the accepted offer; E2E `interviews-offer.spec.ts`.

Out: calendar invitations / email, candidate-facing offer letters, e-signing.

## STOP conditions

- `offers` policies differ from 0006 as quoted in the migration.
- `confirm_hire` no longer accepts `p_start_date` / `p_job_title`.
