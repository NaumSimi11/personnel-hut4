# 071 — Tidying my notifications, and picking task people by typing (migration 0091)

Status: implemented 2026-10-08.

## Why

HR's inbox only grows — every request, task, candidate and handover leaves a
row — and the Notifications page showed the last hundred with no way to
clear any. And the task dialog's "With" was a wall of checkbox pills (on
the live page, empty pills with no names); HR asked for an autocomplete.

## Decisions

- **Archive** (out of sight, kept, restorable) and **delete** (for good)
  your own notifications: picked ones with "Select all", or every read one
  ("Archive all read", "Delete all read"), or every archived one ("Delete all
  archived"). Totals are counted on the server, past the hundred shown.
- Own rows only (`archive_notifications`, `restore_notifications`,
  `delete_notifications`, security definer on `person_id = me`). The bulk
  forms never take an unread row; a delete with no target deletes nothing.
  Deleting a row whose email is pending cancels the email.
- The holding-wide clean-up of everyone's notifications and the audit trail
  (with its own capability) is the separate 2026-10-06 design, not this.
- **"With" on a task** is an autocomplete: chips with ×, up to eight
  suggestions as you type (name start, then a word start, then anywhere;
  accents and the Turkish ı folded), arrows / Enter / Escape / Backspace.

## What changed

- `supabase/migrations/0091_tidy_notifications.sql`; smoke block `0091`.
- `app/src/lib/notificationTidy.ts` (+test), `stores/notifications.ts`,
  `pages/NotificationsPage.vue`, `types/database.ts`.
- `app/src/lib/tasks.ts` (`suggestGuests` replaces `orderGuests`),
  `components/tasks/PeopleAutocomplete.vue`, `TaskDialog.vue`; E2E
  `tasks.spec.ts` types and picks.
