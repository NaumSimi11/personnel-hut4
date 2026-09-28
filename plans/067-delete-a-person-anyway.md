# 067 — Deleting a person who was somebody (migration 0087)

Asked for in the directory with the screenshots of 28 September: every row
shows Remove greyed out, and "they're looking for delete here". The app is
still a test version, and a test person with an employment, a leave request
and a kudos could not be got rid of at all.

## What existed

- **Remove** archives (`8c68a31`). Hidden, restorable, and disabled for
  anyone with a current employment and for yourself.
- **Delete** (plan 065, migration 0084) only on archived rows, and only for a
  record with no history. 93 of the 98 foreign keys pointing at `people`
  block a delete, and an employment period has six blocking children of its
  own.

## The rule now

`delete_person(p_person_id, p_force)`, the way 0082 did it for applications.
Off, nothing changes. On:

1. **Rows about them go.** Employments and all that hangs off one, leave,
   their documents and signatures, kudos received *and given*, interview
   scorecards they wrote, tasks and checklists for them, equipment records,
   access, policy acknowledgements. Children before parents, in one
   transaction, so a failure halfway leaves the person untouched.
2. **Rows about something else stay and forget who.** Every "approved by",
   "uploaded by", "manager", "owner", "assignee", "hiring manager" and
   "company director or HR contact" column becomes null, as the activity log
   already does for a deleted actor.
3. **Two "who" columns cannot be null.** A task somebody else still has to do
   and an equipment handover already under way are reassigned to the admin
   doing the delete.
4. **The sign-in goes first**, through `POST /api/auth/remove-access`, which
   is the only part that needs the secret key. `people.user_id` goes null by
   its key and the database gate is then satisfied honestly. If the delete
   then refuses, the person is intact and merely signed out, which Reset
   access undoes.
5. **Files.** The function returns the storage paths of their documents and
   the app removes the objects, since SQL cannot reach Storage.

The foreign keys are *not* rewritten to cascade. Admins may delete a `people`
row directly under RLS, and a cascade would turn that stray delete into a
silent wipe. This stays the one door.

## What it costs, said first

`person_delete_cost` counts employments, leave requests, documents, kudos,
tasks, equipment records, checklists and whether they have a sign-in. The
confirmation reads it before the click: *"This takes 2 employments, 14 leave
requests, 3 documents, 1 kudos, and their sign-in with them."* The button label
is "Delete them and everything on them" when anything is on record.

## Where it is

Beside Remove on every row of the directory, admins only, disabled only for
yourself. Remove stays the archive for a real person.

## Verified

Unit tests for the verdict, the wording and the account-removal rule. The
migration was run inside a rolled-back transaction on the live database with a
seeded person (employment, leave, document, kudos both ways, a task for them,
a task by them for someone else, a checklist, the company's HR contact, a line
of activity): cost counted, plain delete refused, forced delete left nothing,
the other person's task reassigned, the company's contact cleared.
