# Plan 018a: Candidate page — files, screening answers, decision

> Executor: follow step by step, verify every gate, touch only in-scope files,
> STOP instead of improvising on drift. Reviewer maintains plans/README.md.

## Status

- **Priority**: P1 / **Effort**: L / **Risk**: MEDIUM / **Depends on**: main (post-017, `0071e71`)
- **Category**: feature (blueprint §4 Review: "record evidence, next action,
  interview feedback — visible owner, deadline, and stage history"; core plan
  §9 Applicants: attach résumé, add note, assign owner/next action, reject,
  withdraw). First half of the candidate-review depth; 018b adds interviews,
  blind scorecards and the offer builder.

## Why this matters

Review today is a stage badge and four buttons on a list row. A serious
review has the candidate's material in one place (CV, cover letter, answers
to the job's screening questions), a named owner with a next action and a
date, notes with authorship, and rejections with a recorded reason. The
schema already has `applications.owner_id / next_action / next_action_due /
rejected_reason / withdrawn_reason` and `application_events(kind 'note')`;
what is missing is a candidate page, private file storage, and the answers
column.

## Migration 0013

- `application_files` (id, application_id → applications on delete cascade,
  company_id derived by trigger from the application, kind
  'cv'|'cover_letter'|'portfolio'|'other', storage_path unique, original_name,
  mime_type, size_bytes, uploaded_by → people, extracted_text (null; plan
  020), created_at). RLS: select `candidates.view` in company_id; insert /
  delete `candidates.review`. Audited.
- Storage bucket `candidate-files`: private, 10 MB, PDF / Word / text / PNG /
  JPEG. Object path `{application_id}/{file_id}.{ext}`. Policies resolve the
  application from the first path segment via
  `app.application_company(uuid)` (security definer) and check
  `candidates.view` (select) / `candidates.review` (insert, delete).
- `applications.screening_answers jsonb not null default '[]'` —
  `[{question_id, answer}]`.

## Scope

In:
1. Migration 0013 + smoke tests (company derivation, RLS by company,
   bucket privacy, cross-company refusal).
2. `ApplicationPage.vue` at `/hiring/applications/:applicationId`: header,
   Files card (upload by kind, signed-URL download, remove), Screening
   answers card (job questions × answers, editable with candidates.review),
   Timeline (stage changes + notes, add note), Decision panel (owner, next
   action, due; stage actions; Reject dialog with required reason; Withdraw
   with reason; Confirm hire reuses the dialog).
3. Job Applications tab: rows link to the candidate page and show owner /
   next action due.
4. `lib/applicationFiles.ts` (validation, path, kinds, signed URL) and
   `lib/screeningAnswers.ts` (merge questions × answers) with unit tests;
   E2E `candidate-review.spec.ts`.

Out: interviews, scorecards, offers (018b); public intake (019); AI (020);
candidate-facing emails.

## Steps

1. Smoke assertions → local-verify RED → migration → GREEN → apply live →
   regen types.
2. RED unit tests → GREEN.
3. RED E2E → build page + components + route + job rows → GREEN.
4. Full suite; `/code-review medium`; fix; re-verify.
5. Commit; update plans/README.md and development-plan.md.

## STOP conditions

- `applications` RLS differs from candidates.view / candidates.review.
- The storage schema on the live project lacks `storage.objects.name` path
  semantics (`split_part(name, '/', 1)` is the application id).
