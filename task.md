# Round 03 — where it stands, 23 Sep 2026

Everything marked DONE is on `main` and live on personnel-hut4.vercel.app.
Migrations 0071–0079 are applied to the live database.

Original notes kept word for word, with what happened to each.

---

## Done (14 of 22)

**companipanies - structure - hide it. only on hut4 if must.**
Done — the company page keeps Structure to the holding only. `99ebbda`

**company - hiring. we need to be able to delete**
Done — from the company page (`a8df79c`), and now from the Job openings list
too, with close / abandon beside it. Plan 056, migration 0071.

**company -> equipmpnt remove it**
Done. `99ebbda`

**Project hide - needs to be workt on it later.**
Hidden. `99ebbda` — the "later" work is still later.

**Company activity / activity, onlu ivana, filter by main.**
Done — plan 059, migration 0073. The panel used to load the 200 most recent
rows and filter *those*, so after the import wrote 12,302 rows in a day,
searching for a name searched inside the import and found nothing. Every
filter is now part of the query, and the actor dropdown is built from the
whole trail. Hut4's list is exactly Ivana and Naum. Hut4 also shows the 8,201
rows that belong to no single company (candidates and their files), which were
on nobody's page before.

**people & access , we need delete ( we have manage access & remove access )**
Done — removable from the directory, and restorable. `8c68a31`

**hiring: sub-status - we need to have eduit on the status**
Done. `38dd0de` — and migration 0078 fixed a bug that would have broken it on
any fresh database: the table had an admin-write policy but only ever granted
SELECT. It worked on live purely because Supabase grants DML by default.

**hireing - we need to b abel to edit the labels on the sources.**
Done, same slice, same fix. `38dd0de` + 0078.

**ook, so we need to be bale to add an existing cancidate to another
possiotion ( transver possition to opening or not openings )**
Done — plan 060, migration 0074. Draft jobs are offered now (the database
always allowed them; only the picker did not), every option says its status,
the candidate record shows the job's status, and **Take back** undoes an
attachment while it is still nothing but an attachment — not imported, nobody
hired, nobody carrying it, still at New, no events, interviews, offers or
files. On live, 0 of 4,157 applications are detachable, so it protects
mistakes from here on and cannot reach anything that exists.

**templated for offer.** → see Left.

**equipment - print inentory list.**
Done. `2e94fbf`

**my tasks - how cna we use them - i want to add task to myself, connect some 1
to my task, and the higher profiles can assign tasks to me.**
Done — plan 057, migration 0072. All three: write one for yourself, connect a
colleague who can then work and tick it, and be given one by HR or by the
manager named on your employment. A task is seen by the people on it and
nobody else — not HR, not an admin.

**onobading, we need to add access to the actual worek. - the manager mange
that access, and on the offboarding we need to have preview what we need to
shut down.**
Done — plans 061 and 062, migrations 0075–0079. A list of systems, a record
per person of what they were given and when it was taken away, and "Access to
shut down" on the offboarding checklist. Kept by IT, the manager, or an admin;
never by the person themselves. Both checklist lines now answer themselves.

**export from ht leaves, to be moved in the leave in personal.**
Built — plan 058, no migration. The same two sheets HT's manager desk hands
out, from its own source, filtered by exactly what the leave desk is showing.
**Not yet run against live data** — see Waiting on you.

---

## Left

**Connection to teams.**
Nothing exists. No design discussed yet.

**Conneciton to zoho.**
Recruit is fully imported (3,611 candidates, 4,157 applications, 2,710 files,
plus notes, interviews and reviews) but that was a one-off CSV import — there
is no live connection or sync. Zoho Projects was dropped by your decision on
22 Sep.

**templated for offer.**
Nothing yet. An offer is still salary, currency and start date, with no letter
and no template. Self-contained, needs no keys, and reuses the PDF machinery
that already prints the equipment forms. **This is the next one up.**

**integration with carriers page.**
The careers pages exist. What is missing depends on what you meant: embedding
them on the real hut4 site, or pulling applicants in from it. Needs a sentence
from you.

**Onbaording - when we are thrre, each step on completition should se dn an
emails to the dedicatd ppl ( if it, send to it )**
Nothing fires per line today; the handover mails on four events only. Blocked
twice over — no RESEND_API_KEY, and no IT owner configured to send to. Worth
doing right after those two are sorted.

**back from archie. - hiring - candidates { id }**
Unclear, and I could not reproduce it. Archive and restore both work on the
candidate record, and the pool has "Show archived". This reads like a broken
link — if you hit it again, send me the URL.

---

## Decided against

**starter kit, we shoyld go and filtr by the actual field.**
Skipped, on my recommendation and your agreement. Only two of five companies
have a kit at all (Hut4 7 items, Synami 6); at 42 people the cost of a wrong
item is one IT request edited by hand. Fifteen minutes to add whenever it
starts to hurt.

---

## Still open questions

**- Propmtion - what is it and do we need it**
There is a JobPromotionPanel for promoting a job listing — probably not what
you meant. Keep or cut?

**- -chanels?**
JobChannelsPanel exists, for publishing a job to destinations. Same question.

---

## Waiting on you, not on code

- **RESEND_API_KEY and EMAIL_FROM.** Neither is in `.env.local`. If they are
  set in Vercel, production sends and nothing can be tested locally. Nothing
  emails until both exist — invites, leave decisions, handover, the per-step
  onboarding mails above. Note 10 handover sends are already queued and will
  fire when the key lands.
- **Record the managers.** 0 of the live employments name one, so the manager
  half of access, and four seeded checklist lines, still reach nobody. The
  employee record's corrections already edit it.
- **Set an it_owner per company** (Settings → workflow owners). 0 configured,
  so the 12 IT checklist lines have nobody to go to and handover mail to IT
  has no destination.
- **Grant `candidates.source`** to the Holding HR people, or only admins see
  the talent pool tab.
- **Run the leave report once.** `cd server && npm run dev`, open the leave
  desk, click Download report. I would rather you saw the file before finance
  does.
- **The E2E specs for the last four slices are written but never run.**
  `app/playwright.config.ts` refuses without `E2E_ALLOW_PRODUCTION=true`,
  because those specs seed and hard-delete rows in the live project. Your call.
