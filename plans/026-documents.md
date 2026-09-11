# Plan 026: Documents — employee and company documents with versions

> Executor: follow step by step, verify every gate, touch only in-scope files,
> STOP instead of improvising on drift. Reviewer maintains plans/README.md.

## Status

- **Priority**: P1 / **Effort**: M / **Risk**: MEDIUM (restricted files) / **Depends on**: main (post-025, `5c79544`)
- **Category**: feature (blueprint "documents & policies"; product plan §3
  documents per person and per company, versions never overwritten,
  visibility `hr_only` / `person_and_hr` / `company_public`)

## Migration 0019

- `documents` gains `original_name`, `mime_type`, `size_bytes`, `note`; the
  storage path is unique. Company-level categories are seeded
  (`registration`, `insurance`, `third_party_agreement`, `company_other`).
- `app.prepare_document()` (before insert, SECURITY DEFINER): `uploaded_by`
  is always the signed-in person; a person document needs an employment
  period for that person in that company; a person-scoped category cannot
  describe a company document and vice versa; a new version names the
  document it supersedes (same company and person, not archived), takes
  `version + 1`, and archives the old one — history is never overwritten.
- Private bucket `employee-documents` (20 MB; PDF, Word, PNG, JPEG) at
  `{company_id}/{person_id|company}/{document_id}.{ext}`. Storage policies:
  read an object only when a `documents` row the viewer can see points to it
  (the table's RLS is the gate); upload / delete need `documents.upload` in
  the company named by the path.

## App

- `lib/documents.ts`: bucket constants, validation, object path, upload
  (object → row, orphan removed on failure), signed URL, archive,
  visibility options; unit tests.
- `DocumentsCard.vue`: person mode (across the person's employments) and
  company mode. Lists live documents (archived on request) with category,
  version, visibility, who/when; Open (signed link), New version, Archive
  for `documents.upload`; upload form with title, category, visibility, file.
- Person profile right column, My workspace ("My documents", read-only
  unless the viewer can upload), company profile **Documents** tab.

Tests: smoke (server-set uploader, scope, category rule, versioning,
storage policies), unit, E2E `documents.spec.ts` (upload → open link →
new version → archived history → company document).

Out (026b): document requests and self-service submission; policies with
acknowledgements.
