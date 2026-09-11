# Plan 003: Escape company names consistently in every HTML template

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat a690d31..HEAD -- prototype/app.js`
> prototype/app.js will already contain plan 002's four small fixes (hashchange
> guard, hiringPage guard, companies-length metric, activity cap) — that is
> expected, not drift. Line numbers below are from `a690d31` and may shift by a
> line or two; match on content. Any OTHER mismatch with the excerpts is a STOP
> condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: plans/002-navigation-and-robustness.md
- **Category**: security
- **Planned at**: commit `a690d31`, 2026-09-10

## Why this matters

The prototype's convention is to escape every dynamic value rendered into HTML through the `esc()` helper (`prototype/app.js:5`), and it does so for all user-editable fields (names, titles, notes). But company names (`c.name`, `company(...).name`) and the company initial (`c.short`) are interpolated raw in ~17 templates while being escaped in ~5 others. Today company names are seeded constants ("Company A"…), so this is inconsistency, not a live vulnerability — but the design doc says real, user-provided company names are coming next round (`docs/design-round-01.md:49`: "Names and company labels are placeholders. Company names, branding… are still needed"). At that point every raw site becomes an XSS sink. Fix the inconsistency now, while it's mechanical.

## Current state

`prototype/app.js` — the escape helper and the convention exemplar:

```js
// app.js:5
const esc = value => String(value ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
// app.js:74 — exemplar of the convention applied to a company name:
$('#company-select').innerHTML=`<option value="all">All companies</option>${state.companies.map(c=>`<option value="${c.id}">${esc(c.name)}</option>`).join('')}`;
```

Every raw interpolation site to fix. Each bullet gives the function, the exact current fragment, and the target. Do not change anything else on those lines.

1. `companyPage` all-companies grid (~line 89): `<h2>${c.name}</h2>` → `<h2>${esc(c.name)}</h2>`; and `<div class="company-icon" style="background:${c.color}">${c.short}</div>` → `>${esc(c.short)}</div>` (also apply the `c.short` escape at the two other company-icon sites, ~lines 85 and 97).
2. `companyPage` overview tab (~line 93): `<small>Director · ${c.name}</small>` → `${esc(c.name)}`.
3. `companyPage` integrations tab (~line 96): `Every destination belongs to ${c.name}.` → `${esc(c.name)}`.
4. `companyPage` banner (~line 97): `<h1>${c.name}</h1>` → `<h1>${esc(c.name)}</h1>`.
5. `peopleRows` (~line 102): `<td>${company(p.company).name}</td>` → `<td>${esc(company(p.company).name)}</td>`.
6. `renderAccess` (~line 114), three sites: `Employed by ${company(p.company).name}` → wrap in `esc()`; the company options `` `<option value="${c.id}" ${c.id===d.companyId?'selected':''}>${c.name}</option>` `` → `${esc(c.name)}`; the preview `<small>${company(d.companyId).name} only</small>` → wrap in `esc()`.
7. `hiringPage` (~line 137): the head eyebrow `head('RECRUITMENT / '+company(j.company).name.toUpperCase(),…)` → `head('RECRUITMENT / '+esc(company(j.company).name.toUpperCase()),…)`; the job-select options `${company(job.company).name} · ${esc(job.title)}` → wrap the company name in `esc()`.
8. `hiringPage` brief card (~line 138): `<div class="eyebrow">${company(j.company).name}</div>` → wrap in `esc()`.
9. `jobView` (~line 141): `<h3>LinkedIn · ${company(j.company).name}</h3>` → wrap in `esc()`.
10. `promotionView` (~line 142): `${company(j.company).name} · LinkedIn company page` → wrap in `esc()`.
11. `candidatesView` (~line 143): `sample application(s) · ${company(j.company).name}` → wrap in `esc()`.
12. `handoffView` (~line 144), two sites: `onboarding plan in ${company(j.company).name}.` and the same expression in the inline-note → wrap both in `esc()`.
13. `openHire` (~line 148), attribute context: `<input id="hire-company" value="${company(j.company).name}" readonly>` → `value="${esc(company(j.company).name)}"`.
14. `planSummary` (~line 150): `<small>${company(p.company).name} · Starts ${esc(p.start)}</small>` → wrap in `esc()`.
15. `onboardingPage` (~line 151): `<p>${company(p.company).name} · ${esc(p.title)}…` → wrap in `esc()`.
16. `activityRows` (~line 152): `<small>${company(a.company).name} · Admin (demo)…` → wrap in `esc()`.
17. `candidate-detail` handler (~line 185): `<small>${company(j.company).name} · ${esc(j.title)}</small>` → wrap in `esc()`.

**Deliberate exceptions — do not change** (both are *data strings*, not HTML sinks):

- `peopleRows` (~line 100) builds a *search haystack*: `` `${p.name} ${p.title} ${p.department} ${company(p.company).name}`.toLowerCase() ``. Escaping it would corrupt search matching for names containing `&`/quotes.
- `request-promotion` handler (~line 182/183) builds `j.promotion.copy` as plain text; it is rendered later through `esc(p.copy)` in `promotionView` (~line 142/143). Escaping at the source would double-escape at render.

After all fixes these must be the ONLY two remaining raw `${company(` interpolations.

*(Revision note, 2026-09-10: the original plan listed only the first exception and expected exactly 1 remaining match; the executor correctly STOPped on finding the second site. Verified as a render-time-escaped data string and added as exception. Item 12 also overcounted: `handoffView` has one site, not two.)*

Already-escaped sites (leave as-is, they are the convention): `app.js:74`, `app.js:82` (`esc(scopedName())`), `app.js:85` (`esc(c.name)` in overview company cards), `app.js:145` (`esc(company(j.company).name)` in careersPreview), `app.js:176` (connection modal), and every `badge(...)` call (badge escapes internally, `app.js:65`).

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Install deps | `npm install` then `npx playwright install chromium` | exit 0 |
| Syntax check | `node --check prototype/app.js` | exit 0 |
| Tests | `npm test` | all 4 baseline tests pass |

## Scope

**In scope**: `prototype/app.js` only.

**Out of scope**: everything else, including `btn()`'s unescaped `text` parameter (all call sites pass author-controlled strings, some intentionally contain HTML arrows — changing it breaks buttons) and the seeded-data values themselves.

## Git workflow

- Branch from plan 002's result: `git checkout -b advisor/003-consistent-html-escaping advisor/002-navigation-and-robustness`
- Commit style: `fix: escape company names and initials in all HTML templates`
- Do NOT push or open a PR.

## Steps

### Step 1: Apply the 17 site fixes

Work through the numbered list above top-to-bottom. Mechanical wrapping only — no refactors, no helper extraction.

**Verify**: `node --check prototype/app.js` → exit 0.

### Step 2: Confirm no raw sites remain

**Verify**:
- `grep -Fn '${c.name}' prototype/app.js` → no matches
- `grep -Fn '${c.short}' prototype/app.js` → no matches
- `grep -Fn '${company(' prototype/app.js` → exactly 2 matches: the `peopleRows` search-haystack line and the `request-promotion` copy-template line

### Step 3: Full suite

**Verify**: `npm test` → all 4 tests pass (seeded names contain no escapable characters, so rendered text is unchanged).

## Test plan

No new tests: with seeded data the rendered output is byte-identical, so the baseline suite passing proves no behavioral change. A meaningful XSS regression test requires editable company names, which land in a future round — noted in Maintenance.

## Done criteria

- [ ] `node --check prototype/app.js` exits 0
- [ ] `npm test` exits 0, 4 passed
- [ ] The three greps in Step 2 return exactly the stated results
- [ ] Only `prototype/app.js` modified relative to the base branch (`git diff --stat advisor/002-navigation-and-robustness`)

## STOP conditions

Stop and report back (do not improvise) if:

- A listed fragment cannot be found verbatim (content drift beyond plan 002's known edits).
- The step-2 greps still show raw sites you cannot map to the numbered list (the list may be incomplete — report the extra sites rather than improvising fixes).
- `npm test` fails twice after your changes.

## Maintenance notes

- When editable company names land, add a test seeding a name like `A&B <Test> Co` and asserting it renders literally everywhere.
- Future templates must follow the same rule: every `${...}` that lands in HTML goes through `esc()` unless it is a compile-time constant. Reviewers should check new plans' snippets for this (plans 004–007 were written with `esc()` already applied).
