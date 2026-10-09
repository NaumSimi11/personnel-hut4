# 074 — The starter kit says what went out, and tells who hands it over (migration 0094)

Status: implemented 2026-10-09.

## Why

Three things HR hit on the starter kit after plan 072:

1. An issued line said only "Issued 2026-10-09" — the asset that went out
   had left the free list, the only one the page read names from.
2. "Badge / access card" and "Desk & chair" could never match anything: the
   register had no such equipment types.
3. "When we assign someone a laptop, who needs to know WHAT laptop, to pick
   it up?" Nobody was told.

## Decisions (maintainer, 2026-10-09: "both are real, do that", and the notification)

- An issued line keeps what went out (`asset`: tag, model, type, owner) and
  shows it: "Issued 2026-10-09 · LT-0012 · ThinkPad T14 · Laptop · Synami".
  Lines issued before this know only "a registered asset".
- Equipment types **Badge** and **Furniture** exist, so they can be
  registered and matched ("card", "pass"; "desk", "chair", "table"). A line
  with nothing of its kind free is a plain tick box — "Not tracked as
  equipment — tick it when it is handed over" — with "Pick an asset anyway".
- Issuing a registered asset through the kit notifies the **IT owner of the
  company that owns the asset** (they keep the stock; the company's IT inbox
  gets the mail when set), else the hire's company's IT owner —
  "Hand over LT-0012 to Ana", with model, type, serial, owner, location,
  hire, company and start date — and **the hire** ("Your starter kit:
  LT-0012 · ThinkPad T14", who hands it over). Not whoever issued it.
  No free asset has a location recorded yet, so the line says so.

## What changed

- `supabase/migrations/0094_kit_says_what_went_out.sql` (types,
  `app.it_owner_of`, `app.notify_kit_issue`, `issue_kit_item`); smoke block `0094`.
- `app/src/lib/kitAssets.ts` (`hasMatchingStock`, `issuedLabel`, the new
  kinds, the `vehicle` key), `lib/equipment.ts` (`KitItem.asset`),
  `components/equipment/StarterKitCard.vue`; tests.
