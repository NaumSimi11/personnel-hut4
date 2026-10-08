# 069 — Removing a hiring status (migration 0089)

Status: implemented, migration 0089 not yet applied to the live database.

## Why

0088 let an admin add, rename, retire and restore statuses. Retiring left
every application that had one where it was, and nothing could be deleted.
HR wants to take a status away and say where its applications go — fold
"Interview 4" into "Interview 3" — or delete one that was a typo.

## Decisions (2026-10-08; the maintainer chose "only piece 1")

- **D1 Remove replaces Retire** on the Labels page. The four statuses the
  rules name (`applied`, `sourced`, `contact_attempted`, `contacted`) still
  cannot go; renaming them is the way. Making those rules configurable was
  piece 2 and is not built.
- **D2 The dialog asks first.** `sub_status_usage(key)` counts the
  applications that carry it and the timeline entries that mention it.
- **D3 Where they go.** With applications on it: move them all to another
  live status of the same stage, or leave them as they are and stop
  offering it. "Review them first" opens Hiring → Applicants filtered to
  that stage and status (`?tab=applicants&stage=…&status=…`). No
  per-candidate picker: the filtered list and Set status cover exceptions.
- **D4 Delete or retire.** Deleted when no application has it and no
  timeline entry names it; retired otherwise, so old timelines still read
  the name. Delete is for a mistake, archive is for history (0080).
- **D5 The move is housekeeping.** Each application gets a timeline line
  ("Status "X" removed."), but the candidate's last activity does not move
  and the audit trail gets one summary row (`application_sub_statuses`,
  labelled "Hiring status") instead of one per application. The stored
  reason on Rejected/Withdrawn follows the status where it was only the old
  name. At New or Screening the line is an `outreach` event, which "not
  responding" reads as activity — only reachable when moving into
  `contacted`, an accepted edge.
- **D6 Admins only**, both functions; one transaction per call.

## What changed

- `supabase/migrations/0089_remove_a_status.sql`; smoke block `0089`.
- `app/src/lib/statusRemoval.ts` (+test), `components/hiring/RemoveStatusDialog.vue`,
  `LabelsPanel.vue` (Remove…, Restore stays for retired ones),
  `ApplicantsPanel.vue` (filters from the URL), `lib/activity.ts`,
  `types/database.ts`; E2E `hiring-labels.spec.ts` adds then removes.

## Rollout

Apply 0089 (`psql "$SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f
supabase/migrations/0089_remove_a_status.sql`), then push `main`. The
deployed build does not call the new functions, so the order only matters
for the new Remove button.
