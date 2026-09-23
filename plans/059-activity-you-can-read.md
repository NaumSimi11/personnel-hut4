# 059 — Activity you can actually read (migration 0073)

task.md: *"Company activity / activity, onlu ivana, filter by main."*

## The defect, in numbers

The panel loaded the 200 most recent rows and filtered **those** in the page.
Then the Zoho import wrote 12,302 rows in a single day. On live today:

```
Naum Simidjioski  12,902   ← the import
system            11,374   ← triggers
Ivana Frost           55   ← the actual human work
```

So the 200 most recent rows are all import. Choosing an entity searched inside
the import. Typing "Ivana" searched inside the import. Her 55 changes were
unreachable from the page that exists to show them — which is exactly the
complaint.

The obvious fix — a date filter — does **not** work here: the import ran
*yesterday* (12,302 rows on 2026-09-22), so no period short enough to be
useful excludes it. The filter that matters is **who**.

## What it needs

1. **Every filter moves into the query.** Period, actor and entity are now
   `.gte` / `.eq` / `.is` on the request, so each one fetches the rows it
   describes instead of sieving a window that is already the wrong 200.
2. **An actor dropdown**, which cannot be built from the loaded rows for the
   same reason — the loaded rows are the import. `activity_choices` (0073)
   answers from the whole trail.
3. **The holding sees its holding-wide rows.** 8,201 rows carry no company at
   all — candidates and their files are holding-wide (0067) — so they appeared
   on no company's page. Hut4's page now asks for them too. RLS is unchanged:
   those rows are readable by admins only.
4. The free-text search stays in the page, over what the query returned, and
   the heading says which it is ("37 changes" vs "the 200 most recent
   changes").

## The migration

`public.activity_choices(p_company_id uuid, p_holding_wide boolean)` returns
`{actors, entity_types}` for the whole trail.

**SECURITY INVOKER on purpose** — the default, but stated in the file because
it carries the argument: the two select policies on `activity_log` (0006's
admin / `access.manage` rule and 0012's recruitment rule) then apply to this
query exactly as they apply to the panel's own. A definer function would have
had to restate those rules, and a restated rule is one that drifts. `people`
is joined the same way, so an actor the caller may not see comes back with a
null name and renders as "someone", which is what the panel has always shown.

## Smoke

A `0073` block on its own hand-written `activity_log` rows, because the trail
is a by-product of every other block and asserting against it would couple
this one to all of them: an admin sees every actor and kind and the
holding-wide rows only when asked; Bea (Company HR in B) sees B's actor and
nothing of A's, and the holding-wide flag widens the question without widening
her permission; Omar, who holds nothing, is offered nothing.

## Verified on live

After applying 0073, Hut4's actor list is exactly `Ivana Frost` and
`Naum Simidjioski` — her 37 Hut4 changes, 17 at Synami and 1 holding-wide are
now two clicks away.
