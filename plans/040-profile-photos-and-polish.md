# Plan 040: Profile photos, and love for Leave and Companies

> Executor: follow step by step, verify every gate, touch only in-scope files,
> STOP instead of improvising on drift. Reviewer maintains plans/README.md.

## Status

- **Priority**: P1 / **Effort**: M / **Risk**: LOW (one public bucket, one
  function) / **Depends on**: 039, the style pass (`67ca7c0`)
- **Category**: feature + design. Asked for while testing on the migrated
  data: "people should be able to upload their profile images", "companies
  looks like shit", "leave needs much more love — refer to the old HR".

## Profile photos (migration 0031)

- Bucket `avatars`, public (a face is shown next to the name everywhere, so
  it is fetched by plain URL; the object path carries a random uuid), 2 MB,
  PNG / JPEG / WebP. Objects at `{person_id}/{uuid}.{ext}`.
- Storage policies through `app.can_write_avatar(name)`: the folder must be
  a person id, and the writer is that person (`app.is_self`) or someone who
  may edit the record (`app.can_edit_person`). Everyone may read.
- `set_avatar(person, path default null)`: same gate; the path must sit in
  the person's folder; returns the previous path so the client removes the
  old file. `people.avatar_url` keeps the object path.
- App: `lib/avatars.ts` squares and shrinks the image in the browser
  (256 px WebP — a phone photo never leaves the machine at full size),
  uploads, calls `set_avatar`, removes the previous object. `AvatarImage`
  renders a photo or initials everywhere a face appears (directory, profile
  hero, sidebar, workspace); `AvatarUpload` on My workspace (self) and the
  profile hero (self or an editor) — click the picture to change it, "Remove
  photo" to clear.

## Leave calendar

Ported from Field Notebook's coverage view and the skill's calendar rules:
a stats strip (away today · pending · people and working days this month ·
public holidays), a legend, "Today" and icon month navigation, compact
type-coloured chips ("Filip B.", four per day then "+N more", dashed when
pending, ringed when yours; the full text stays for screen readers and on
hover), today as a filled circle, holidays as a tinted cell with the name,
and a richer day rail (initials, type key, dates, "day 2 of 5" with a
progress bar, note). Company filter sits beside the tabs.

## Companies

The holding as a header band (accent bar, mark, people here and across the
group, place, director / HR); each subsidiary a card that is the link:
accent bar, mark, place, name, tagline, headcount with a stack of faces,
open roles, director / HR contact.

## Verification

- Smoke: own photo set / cleared, colleague refused, wrong folder refused,
  HR may set, storage helper agrees.
- Unit: `avatars.test.ts` (path, URL, validation), `leave.test.ts`
  (`shortName`).
- E2E: `avatar.spec.ts` (add from My workspace → sidebar, directory, record,
  storage → remove); `leave.spec.ts`, `companies.spec.ts`,
  `company-manage.spec.ts`, `transfer.spec.ts`, `people.spec.ts`,
  `my-workspace.spec.ts` green after the restyle.
