# 072 — Free equipment for anyone in the holding (migration 0092)

Status: implemented 2026-10-08.

## Why

The onboarding starter kit offered a hire only their own company's free
assets and the holding pool. Snowball owns none and the pool was empty, so a
Snowball hire saw empty pickers while 120 assets sat free at Synami (93),
Hut4 (18) and Liquiditas (9) — 43 of them laptops, 41 monitors.

## Decision (maintainer, 2026-10-08)

"When the equipment has a relation with a particular employee, we can't give
it to anyone. No other rules exist." So:

- An **available** asset (no reservation, no holder) may go to anyone
  currently employed anywhere in the holding (`counts_as_employed`: active or
  pre-start). It stays on its owner's books; only who holds it changes.
- Who may hand it over is unchanged on the direct doors (`reserve_asset`,
  `issue_asset`: it.assign / it.complete where the asset is). Through the
  starter kit, the kit's own check in the hire's company is enough
  (`issue_kit_item` now calls the core steps `app.reserve_asset_for` /
  `app.issue_asset_for`), and `kit_asset_options` lists the holding's free
  stock past the reader's own asset visibility.
- The kit's picker is searchable: on focus the line's kind first ("Keyboard &
  mouse" → accessories, "Software licences" → licences), typing narrows by
  tag, model, serial, type or owner, each option reads "tag · model · type ·
  owner", and an asset picked on one line is not offered on another.

Not changed: the Equipment page's own "Reserve for" still lists the asset
company's people.

## What changed

- `supabase/migrations/0092_free_equipment_for_anyone.sql`; smoke block `0092`.
- `app/src/lib/kitAssets.ts` (+test), `components/equipment/AssetPicker.vue`,
  `StarterKitCard.vue`, `types/database.ts`.
