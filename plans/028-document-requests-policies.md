# Plan 028: Document requests (self-service) and policies with acknowledgements

> Executor: follow step by step, verify every gate, touch only in-scope files,
> STOP instead of improvising on drift. Reviewer maintains plans/README.md.

## Status

- **Priority**: P1 / **Effort**: M / **Risk**: MEDIUM (self-service writes) / **Depends on**: main (post-027, `2592a87`)
- **Category**: feature (blueprint "documents & policies": HR requests a
  document, the employee submits it, HR accepts or asks for a correction;
  policies are published per company or holding-wide and each person
  acknowledges the version they read)

## Migration 0021

- **Document requests** (`document_requests`, 0004): a before-insert trigger
  pins `status = 'pending'`, `reviewer_id` = requester, checks employment in
  the company and a person-scoped category. `submit_requested_document(
  p_request_id, p_document_id)` (the person, a pending / needs-correction
  request, a document of theirs in that company and category) → `submitted`
  with `fulfilled_document_id`. `review_document_request(p_request_id,
  p_decision accepted|needs_correction|cancelled, p_note)` needs
  `documents.request`; the requester is not excluded (a request is not an
  approval).
- **Self-service upload**: a person may insert a `documents` row for
  themselves when a pending / needs-correction request exists for that
  company and category; `prepare_document` forces such rows to
  `person_and_hr`. Storage: the person may upload into their own folder
  under that company while such a request exists.
- **Policies** (`policies`, 0004): `publish_policy(p_policy_id)` needs a
  file, `policies.publish` in the company (holding-wide: platform admin);
  a re-publish bumps `version` so earlier acknowledgements no longer count.
  `archive_policy(p_policy_id)`. Private bucket `policies` at
  `{company_id|holding}/{policy_id}.{ext}`: readable when a policy row the
  viewer can see points to it; written by publishers.
- `policy_acknowledgements` stays insert-self-only (0006);
  `acknowledge_policy(p_policy_id)` records the current version.

## App

- `lib/documentRequests.ts`, `lib/policies.ts` with unit tests.
- Person profile: **Document requests** card (`documents.request`) — request
  (category, due date, note), list with status, review submitted ones.
- My workspace: **Requested from you** — pending / needs-correction requests
  with an upload form (self-service), submitted ones with status; **Policies
  to acknowledge** — published policies not yet acknowledged at their
  current version, Open + "I have read this"; acknowledged list.
- Company profile → Documents tab: **Policies** section — add (title + file),
  Publish / Re-publish, Archive, acknowledged count over active headcount.

Tests: smoke (pinning, self-service window, review, publish/version,
acknowledgement version, storage), unit, E2E `document-requests.spec.ts`
(HR requests → employee signs in and uploads → HR accepts; publish policy →
employee acknowledges → count on the company tab).
