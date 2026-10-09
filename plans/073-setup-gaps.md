# 073 — What is missing for the app to work (migration 0093)

Status: implemented 2026-10-09.

## Why

HR: "if we don't have an IT guy registered (he is responsible for emails,
access), can we tell that?" On live, not one of the six companies had an IT
owner or an HR owner, nor an IT or HR inbox — so every onboarding's IT lines
("Work account and email created", "Starter kit issued") had nobody (11 open
lines), new IT requests notified nobody, and a blocked one told nobody.

## Decisions (maintainer, 2026-10-09)

- **Banner on Overview** for platform admins (every company) and Company HR
  (companies where they hold `employment.edit`); nobody else asks. Not
  dismissible — it goes when the gap does.
- **Must-haves:** IT owner (onboarding IT lines, IT requests, handovers "to
  the IT owner") and HR owner (blocked IT requests). An archived owner is no
  owner. **Softer:** the IT and HR inboxes (mail falls back to the owner).
  Hiring approver, offer approver and marketing reviewer are not checked —
  nothing reads them today.
- Admins get each company as a link to its Settings tab (owners and inboxes
  are admin-write, 0006); HR is told an admin sets them.
- **Naming the IT owner hands them the company's open IT lines that had
  nobody** (`t5_it_owner_takes_open_lines`): a line's owner is resolved when
  the checklist starts (0077), so without this the banner's fix would not
  reach the onboardings already running.
- An open IT line with nobody says so on the checklist: "nobody — no IT
  owner is set for this company".

## What changed

- `supabase/migrations/0093_setup_gaps.sql` (`setup_gaps`, `app.has_live_owner`,
  the trigger); smoke block `0093`.
- `app/src/lib/setupGaps.ts` (+test), `components/home/SetupGapsBanner.vue`,
  `pages/HomePage.vue`, `lib/checklists.ts` (`unownedNote`, +test),
  `components/checklists/ChecklistTasks.vue`, `types/database.ts`.
