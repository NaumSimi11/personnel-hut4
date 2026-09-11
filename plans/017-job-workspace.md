# Plan 017: Job workspace — channels, promotion, activity

> Executor: follow step by step, verify every gate, touch only in-scope files,
> STOP instead of improvising on drift. Reviewer maintains plans/README.md.

## Status

- **Priority**: P1 / **Effort**: L / **Risk**: MEDIUM / **Depends on**: main (post-016, `947d793`)
- **Category**: feature (blueprint §4 job workspace, §9 step 4 — marketing briefs
  and manual publication records; prototype steps 02 and 03)

## Why this matters

The prototype's hiring journey had five numbered steps; plans 009/010 shipped
01 (request), 04 (applications) and 05 (hire) and left 02 (Job & channels) and
03 (Promotion) out. The job page today is a description box and a candidate
list. The blueprint gives each approved role one workspace — Overview, Job
description, Channels, Applications, Interviews & Offer, Promotion, Activity —
and the schema for all of it already exists (`jobs.screening_questions`,
`job_channels`, `channels`, `promotions`, the audit trigger on all five
recruitment tables). This plan builds the workspace frame and the two missing
steps; 018 adds candidate review depth (Interviews & Offer), 019 the public
careers page, 020 AI assistance.

## Current state (all committed on main)

- `jobs`: status ('draft'|'ready'|'open'|'on_hold'|'filled'|'closed'),
  description, `screening_questions jsonb default '[]'`,
  `description_revision int` (NOT auto-bumped — the app bumps it on save).
  "Prepare job" currently inserts with status 'open'.
- `job_channels` (job_id, channel_key, status 'not_selected'|'ready'|'queued'|
  'submitted'|'live'|'action_required'|'failed'|'closing'|'closed',
  external_job_id, publication_url, published_revision, last_error,
  published_by, verified_by; unique (job_id, channel_key)). RLS: read
  `jobs.view`, write `jobs.publish`.
- `channels` seeded: careers (kind careers), linkedin (social), indeed
  (job_board), other_manual (manual).
- `promotions` (job_id, company_id, channel_key default 'linkedin', brief
  jsonb, copy, status 'requested'|'draft'|'in_review'|'changes_requested'|
  'approved'|'scheduled'|'published'|'failed'|'cancelled', publication_url,
  requested_by, reviewed_by, published_by, deadline; unique (job_id,
  channel_key)). RLS write = OR of marketing.draft/approve/publish/jobs.edit
  — no transition enforcement.
- `activity_log` written by `app.audit()` for jobs, job_channels,
  applications, offers, promotions (and others); readable by admins /
  `access.manage` only.
- `auth.can(companyId, cap)` (plan 016) for UI hints.
- Capabilities: jobs.edit, jobs.publish, candidates.view/review,
  marketing.view/draft/approve/publish.

## Scope

In:
1. Migration 0012: `public.advance_promotion(p_promotion_id, p_to_status,
   p_copy, p_publication_url)` enforcing the transition table and the
   capability per step (reviewer ≠ drafter); `activity_log` read policy for
   recruitment entity types to `jobs.view` holders of that company; smoke
   tests.
2. Job page → tabbed workspace: Overview (stepper + facts + counts + status
   actions), Description (+ screening questions editor, revision bump),
   Channels (careers publish/unpublish, manual posting record, provider
   channels shown as not connected, out-of-date indicator), Applications
   (existing list), Promotion (request → draft → review → approve → publish),
   Activity (audit trail).
3. "Prepare job" creates the job as `draft`; publishing the first channel
   opens it; `jobs.edit` can put on hold / close / reopen.
4. Tests: unit (`lib/jobWorkspace.ts`: stepper, screening-question schema,
   promotion transitions), E2E `job-workspace.spec.ts`; `hiring-pipeline.spec`
   updated for tabs and the draft→open lifecycle.

Out: CV files, scorecards, interviews, offer builder (018); public careers
page (019); AI (020); real LinkedIn/Indeed publishing.

## Transition table (promotions)

| From | To | Who |
|---|---|---|
| — | requested | jobs.edit (creates the row with the brief snapshot) |
| requested, changes_requested | draft | marketing.draft (copy required) |
| draft | in_review | marketing.draft |
| in_review | approved / changes_requested | marketing.approve, not the person who drafted |
| approved | published | marketing.publish (publication_url required) |
| any non-terminal | cancelled | jobs.edit |

## Steps

1. Smoke assertions for `advance_promotion` and the activity_log policy →
   local-verify RED → migration 0012 → GREEN → apply live → regen types.
2. RED unit tests for `lib/jobWorkspace.ts` → GREEN.
3. RED E2E `job-workspace.spec.ts`.
4. Build tabs/components; typecheck; GREEN. Update `hiring-pipeline.spec`.
5. Full suite; `/code-review medium`; fix; re-verify.
6. Commit; update plans/README.md and development-plan.md.

## STOP conditions

- `app.audit()` does not write `company_id` for jobs/promotions rows (the
  read policy depends on it).
- The live project's `channels` rows differ from the seed above.
