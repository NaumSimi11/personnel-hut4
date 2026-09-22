# 053 — Search by words (migration 0068)

Follow-up 1 of slice 052. Small: one function replaced, one smoke block, one E2E line, docs.

## The defect

`search_candidates` (0067) turns the query into `app.name_key(q)` — the lower-cased, accent-folded, **sorted** words — and matches `c.name_key like '%<key>%'`. A partial multi-word query only matches when its sorted words happen to be a contiguous run of the candidate's sorted words: "E2E Pool" → `e e pool` misses `e e person pool`; "Ana Il" → `ana il` matches `ana ilievska` only by luck of order; "Petrov Marko" → `marko petrov` matches, "Mar Pet" does not. The E2E spec (`talent-pool.spec.ts`) searches the full name to work around it.

## Decision (the maintainer asked for the follow-up as recorded in docs/session-handoff.yaml)

The name predicate becomes: **every word of the query's key is a prefix of some word of the candidate's key**, order-free. The other predicates (email / title / employer / skills `ilike`, phone key, LinkedIn key) are unchanged. Nothing else in the RPC changes: the same visibility rule, filters, paging, `applications_count`, the capped list.

## 1. Migration `supabase/migrations/0068_search_by_words.sql`

- `create or replace function public.search_candidates(p jsonb)` — copy the 0067 body verbatim except the name clause. Add a local `v_words text[] := regexp_split_to_array(v_name_key, ' ')` (set only when `v_name_key is not null`) and replace
  `(v_name_key is not null and c.name_key like '%' || v_name_key || '%')`
  with
  `(v_words is not null and (select bool_and(c.name_key ~ ('(^| )' || w)) from unnest(v_words) w))`.
  `name_key` holds only `[a-z ]` (the fold table maps every accented letter; `[^[:alpha:]]+` becomes a space), so the words carry no regex metacharacters — no escaping needed; state that in a comment. Keep `security definer`, `set search_path`, the grants exactly as 0067 declares them (re-declare the grant after the `create or replace` so a fresh database is identical).
- Header comment in the 0067 style: what changed, why, what did not.
- No column, index or type change. `app/src/types/database.ts` is untouched (the signature is the same).

## 2. Smoke — `supabase/tests/smoke.sql`

A `0068` block appended before the final `select 'SMOKE TESTS PASSED'` line, in the hand-written `do $$ … assert … $$` style of the 0067 block, using the 0067 block's fixtures (the pool holder Ada, the seeded pool people — read the 0067 block for their names and ids) plus one fresh candidate created through `upsert_sourced_candidate` as Ada with `full_name 'Élena Marija Trajkovska'`:
1. `q 'Traj Mar'` returns her (two prefixes, out of order, accent-folded on the stored side).
2. `q 'elena traj'` returns her (folded on the query side).
3. `q 'Trajkovska Ana'` does NOT return her (`ana` is not a prefix of any of her words) — and does not return a candidate named "Ana …" either unless that person's key also has a `traj…` word.
4. `q 'E2E Pool'`-shaped case: a candidate `'Pool Person Test'` is found by `q 'Pool Test'`, `q 'test pool'` and `q 'Per Po'`, not by `q 'Pool Testx'`.
5. The other predicates still work: an email fragment and a skill still find their rows (one assert each, reusing 0067 fixtures).
6. Counts: `total` in the returned JSON equals the number of rows for a single-word query that matches exactly two seeded people (prove paging arithmetic is untouched).

Run `PATH="/c/Program Files/PostgreSQL/18/bin:$PATH" bash supabase/tests/local-verify.sh` — must end `SMOKE TESTS PASSED` (68 migrations).

## 3. App

- `app/src/lib/candidatePool.ts`: no code change. Add a doc comment on `nameKey` saying the SQL search matches each query word as a word-prefix of the key (order-free), so the mirror's sort is for dedupe, not search.
- `app/e2e/talent-pool.spec.ts`: the pool search step searches the plan's partial `"E2E Pool"` (replace the full-name workaround and its comment) and still asserts `pool-row-<id>` with `1 · latest: E2E Pool Role A`. Run it green on live after 0068 is applied (`cd app && npx playwright test e2e/talent-pool.spec.ts --reporter=line`; `E2E_ALLOW_PRODUCTION=true` is set).
- `cd app && npx vitest run` and `npx vue-tsc --noEmit -p tsconfig.json` once.

## 4. Apply live

The controller applies 0068 (`psql … -1 -v ON_ERROR_STOP=1 -q -f`), verifies with `select count(*) from public.search_candidates('{"q":"Simi"}'::jsonb)` style probe (any real partial that should match at least one imported row), then the E2E runs.

## 5. Docs

`plans/README.md`: a 053 row (DONE after the E2E). `docs/development-plan.md`: Done row `0068 + plan 053`. `docs/session-handoff.yaml`: `state.live_db` says 0001–0068; `follow_ups_from_052` drops item 1; `next.say_to_start` points at the remaining follow-ups / the development plan's Next.

## Out of scope

Full-text search over `extracted_text` / `summary` (a tsvector + `q_text` — plan 052 §5), fuzzy / typo tolerance, ranking. The dedupe match (`upsert_sourced_candidate`) keeps its exact-key rule — search is looser than identity on purpose.
