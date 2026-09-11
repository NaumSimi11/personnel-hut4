# Plan 019: Careers page & application intake

> Executor: follow step by step, verify every gate, touch only in-scope files,
> STOP instead of improvising on drift. Reviewer maintains plans/README.md.

## Status

- **Priority**: P1 / **Effort**: L / **Risk**: MEDIUM (first public surface) / **Depends on**: main (post-018b, `d880c6e`)
- **Category**: feature (blueprint §5 "company careers pages: the first
  dependable intake source"; §5 reliable intake rules)

## Decisions (maintainer, 2026-09-11)

- Public pages live inside this app as sign-in-free routes.
- Spam protection: honeypot field + in-memory rate limiting per IP and per
  email in the auth service. No third party.

## Design

Everything public goes through the auth service with the service role;
anonymous visitors never touch the database directly.

Server (`server/src/careers.ts` pure logic, `server/src/careersRoutes.ts`):
- `GET /api/careers/:code` → company card (name, logo URL, accent, tagline,
  website) + jobs that are `open` with a `live` careers listing (id, title,
  summary).
- `GET /api/careers/:code/jobs/:jobId` → the public brief (description,
  screening questions) + company card. 404 unless open + live.
- `POST /api/careers/:code/jobs/:jobId/applications` (multipart) → fields
  name, email, phone?, answers (JSON), consent, `website` (honeypot), file
  `cv`. Order: honeypot (silent 201) → rate limit (429) → validate (400) →
  job open+live (404) → duplicate (409: same email, same job, non-terminal
  application) → candidate (reuse exact email match, else create) →
  application (`source_channel_key = careers`, answers) → CV object +
  `application_files` row → `{ reference }`.

App: `/careers/:code` (`CareersCompanyPage`), `/careers/:code/:jobId`
(`CareersJobPage`) — public routes outside the shell, branded; success state
with the reference. Channels tab links to the live page.

Tests: server vitest (`careers.test.ts`: rate limiter, input schema,
honeypot, brief shaping, duplicate rule); E2E `careers.spec.ts` (anonymous
context applies with a CV → refused twice → honeypot dropped → admin sees the
application with file, answers, source).

Out: candidate emails (Resend), job-board feeds, custom domain.
