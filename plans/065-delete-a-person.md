# 065 — Deleting a person who was never anybody (migration 0084)

task.md: *"we need to be bale also to delete ppl / archived / delete."*

## Why the directory archived instead

Written down when Remove shipped (`8c68a31`) and still true: of the 98 foreign
keys pointing at `people`, **93 block a delete**. Anyone with an employment, a
leave request, a document, a kudos, a signature or a line of activity cannot be
hard-deleted at all — and the history that blocks it is history worth keeping.

So archive is the right answer for a real person and stays exactly as it is.

## What archive is the wrong answer for

The row that was a mistake: a name typed twice, a test record, an import run
against the wrong file. That person has no history to protect, and leaving them
archived forever is filing a typo.

## The rule

`delete_person` leans on those 93 keys rather than restating them. Four things
are named directly, because they are the answers somebody is most likely to
need:

- **Not yourself.**
- **Admins only**, the same gate the archive has — this is the directory's most
  destructive act and is not delegated.
- **No sign-in.** An account outliving its person can still log in, to an app
  that no longer knows who they are. Access comes off first, through the door
  that already exists.
- **No employment, ever.** If this company employed them, they are somebody.
- **Nothing in the activity trail.** `activity_log.actor_person_id` is SET
  NULL, so deleting an actor quietly rewrites their work as "system".

Everything else is left to the database, and its refusal is translated:
`violates foreign key constraint "kudos_to_person_id_fkey"` becomes *"Has A
Kudos still has kudos on record. Archive them instead."*

## What does cascade, and should

Four things go with the person: their notifications, their queued documents,
the handover sends about them, and `person_private_details` — the national ID
and bank account, which is precisely the record that should not outlive the
person it describes.

## Where it is

Beside **Restore** on an archived row in the directory, admins only. Archive
first, then delete: the two-step keeps the destructive one out of the way of
the ordinary one.
