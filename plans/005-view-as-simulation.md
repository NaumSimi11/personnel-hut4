# Plan 005: Add a clearly-labeled "View as" permission simulation

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat a690d31..HEAD -- prototype/`
> prototype/app.js will already contain plans 002–004 (navigation guard,
> robustness fixes, esc() on company names, unified overview queue) — expected,
> not drift. Line numbers below are from `a690d31` and will have shifted; match
> on content. Any other mismatch with the excerpts is a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED (touches render() and both global event handlers)
- **Depends on**: plans/004-needs-action-queue.md
- **Category**: direction
- **Planned at**: commit `a690d31`, 2026-09-10

## Why this matters

The prototype stores rich per-person × per-company permission grants, but nothing ever *consumes* them — the whole UI runs as Admin, so stakeholders cannot see what "Sam is a manager but cannot see payroll yet" actually looks like. The blueprint explicitly calls for this: "Preview mode is a clearly labeled simulation, not silent impersonation" (`docs/hr-system-blueprint.md:70`), and the design doc's open review questions 2–4 (`docs/design-round-01.md:59-63`) can only be answered by seeing the portal through a person's grant. This plan adds a "View as" mode: pick a person, the workspace renders only what their grant for the selected company allows, with a prominent simulation banner and one-click return to Admin.

This is still a design simulation, not security: it gates rendering and handlers in the browser. Keep the existing disclaimers intact.

## Current state

All in `prototype/`. Key facts (line numbers from `a690d31`):

- Global state vars (`app.js:54-55`): `let scope='all', page=..., companyTab='overview', hiringStep='request', jobId='j0', query='';`
- Grants live in `state.grants` keyed `personId+'|'+companyId` → `{preset, permissions:[...]}` (`app.js:47-48`). Permission ids and labels come from `groups` (`app.js:7-16`); e.g. `people.view`, `jobs.view`, `jobs.approve`, `tasks.view`, `tasks.complete`, `access.manage`, `marketing.approve`.
- Seeded presets per company (`app.js:48`): person index 0 = `Company Director` (has `people.view, jobs.view, jobs.request, jobs.approve, candidates.view, tasks.view`), index 1 = `Company HR`, index 5 = `Marketing` (`marketing.view, marketing.draft` only), index 6 = `Finance` (`people.view, salary.view, payroll.summary, payroll.individual`), everyone else `No access`. So in Company A (c1): Alex Morgan = Director, Maya Chen = HR, Emma Brooks = Marketing, Noah Bennett = Finance.
- `render()` (`app.js:72-78`) rebuilds `#company-select`, `#navigation` (from a local `nav` array of `[id, icon, label]`), and `#main` on every action. The page whitelist is at `app.js:73`.
- Topbar (`prototype/index.html:19`):
```html
<header class="topbar"><div class="scope"><span class="scope-icon" aria-hidden="true">▦</span><label for="company-select">Company</label><select id="company-select" aria-label="Company scope"></select></div><div class="top-actions"><span class="demo-pill">DESIGN PROTOTYPE</span><button class="text-button" id="reset-demo">Reset demo</button></div></header>
```
- Prototype note bar (`prototype/index.html:20`):
```html
<div class="prototype-note">Sample names and records · Changes are saved in this browser only · External publishing and access enforcement are simulated.</div>
```
- Click handler: one delegated listener switching on `data-action` (`app.js:155-194`). Change handler for selects (`app.js:195-205`). Submit handler switching on `form.id` (`app.js:207-231`).
- `toast(message)` (`app.js:61`) shows a transient notice.
- After plan 004, `overview()` builds a `needs` array of three mapped groups (hiring requests / promotions in review / onboarding gaps), each row's `{title, sub, action}`.
- CSS conventions: tokens on `:root` (`styles.css:1`), utility classes like `.inline-note`, `.demo-pill`; amber tone pairs `#fbf2df`/`#946d24` (`.badge.amber`, `styles.css:3`).

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Install deps | `npm install` then `npx playwright install chromium` | exit 0 |
| Syntax check | `node --check prototype/app.js` | exit 0 |
| Tests | `npm test` | all prior tests + 3 new pass |

## Scope

**In scope**:
- `prototype/app.js`
- `prototype/index.html` (topbar select + banner element)
- `prototype/styles.css` (banner + select styling only)
- `tests/view-as.spec.js` (create)

**Out of scope**: `docs/`, root `index.html`, `hr-system.html`, `tests/walkthrough-*.spec.js`, `tests/needs-action.spec.js` (they run as Admin and must keep passing untouched — Admin behavior must not change).

## Git workflow

- Branch from plan 004's result: `git checkout -b advisor/005-view-as-simulation advisor/004-needs-action-queue`
- Commit style: `feat: add view-as permission simulation with capability gating`
- Do NOT push or open a PR.

## Steps

### Step 1: Markup — view-as select and simulation banner

In `prototype/index.html` topbar, inside `<div class="top-actions">`, before the demo pill, add:

```html
<label class="scope" style="gap:8px"><span class="field-label" style="font-size:11px">View as</span><select id="view-as" aria-label="View workspace as"></select></label>
```

Directly after the `.prototype-note` div, add an empty banner container:

```html
<div id="viewas-banner" hidden></div>
```

In `prototype/styles.css`, append one rule block (keep to one line, matching file style):

```css
#viewas-banner{display:flex;align-items:center;gap:12px;font-size:11px;padding:10px 42px;background:#fbf2df;color:#946d24;border-bottom:1px solid #f0e3c3}#viewas-banner strong{color:#7a5a1d}#viewas-banner button{margin-left:auto}#viewas-banner[hidden]{display:none}
```

**Verify**: open `http://127.0.0.1:8317/prototype/` manually or proceed — structural check: `grep -c 'id="view-as"' prototype/index.html` → 1.

### Step 2: State and capability helper

In `app.js`, after the `let editorDraft=...` line (~55), add:

```js
let viewAs=null;
const viewer=()=>viewAs?person(viewAs):null;
const can=cap=>{if(!viewAs)return true;if(scope==='all')return false;const g=state.grants[viewAs+'|'+scope];return !!g&&g.permissions.includes(cap);};
```

`viewAs` is deliberately session-only — do NOT persist it to localStorage (the stored shape must stay version-1 compatible).

### Step 3: Entering, leaving, and constraining scope

In the `change` handler, add a branch for `#view-as` (next to `company-select`):

```js
else if(target.id==='view-as'){viewAs=target.value||null;if(viewAs)scope=person(viewAs).company;else if(!state.companies.some(c=>c.id===scope))scope='all';companyTab='overview';page='overview';location.hash='overview';render();}
```

In the `company-select` branch, nothing changes (a simulated user may switch companies to inspect each independent grant — that is the design point from `docs/design-round-01.md:15`), but the `all` option must be unavailable while simulating. In `render()`, build the company select as:

```js
$('#company-select').innerHTML=`${viewAs?'':'<option value="all">All companies</option>'}${state.companies.map(c=>`<option value="${c.id}">${esc(c.name)}</option>`).join('')}`;
```

(and if `viewAs&&scope==='all'` set `scope=viewer().company` just before that line).

### Step 4: Populate the view-as select and banner in render()

In `render()`, after the company-select rebuild, add:

```js
$('#view-as').innerHTML=`<option value="">Admin (you)</option>${state.companies.map(c=>`<optgroup label="${esc(c.name)}">${state.people.filter(p=>p.company===c.id).map(p=>`<option value="${p.id}" ${p.id===viewAs?'selected':''}>${esc(p.name)} · ${esc(p.title)}</option>`).join('')}</optgroup>`).join('')}`;$('#view-as').value=viewAs||'';
const banner=$('#viewas-banner');banner.hidden=!viewAs;if(viewAs){const v=viewer(),g=state.grants[viewAs+'|'+scope];banner.innerHTML=`<span>SIMULATION</span><strong>Viewing as ${esc(v.name)}</strong><span>${esc(v.title)} · ${esc(company(scope).name)} · ${g?g.permissions.length:0} capabilities here</span>${btn('Return to Admin','exit-view-as','','secondary small')}`;}
```

### Step 5: Gate navigation and pages

Replace the `nav` array + whitelist logic in `render()` (`app.js:73-76`). Define page requirements next to the nav array:

```js
const pageCaps={overview:null,company:null,people:'people.view',hiring:'jobs.view',onboarding:'tasks.view',activity:'access.manage'};
```

Filter nav entries with `.filter(([id])=>!pageCaps[id]||can(pageCaps[id]))`, and harden the page whitelist: if the current `page` has a requirement the viewer lacks, fall back to `'overview'` before rendering. Admin (`viewAs===null`) sees everything unchanged.

Also gate `companyPage` tabs: build `tabs` filtered so `people` requires `people.view`, `access` requires `access.manage`, `hiring` requires `jobs.view`, `integrations` requires `integration.view` (overview always). If the active `companyTab` is filtered out, reset it to `'overview'`.

### Step 6: Gate actions centrally

At the top of the click handler (after resolving `target` and destructuring, before the `if/else` chain), add:

```js
const actionCaps={'approve-request':'jobs.approve','request-changes':'jobs.approve','publish-careers':'jobs.publish','manual-publication':'jobs.publish','request-promotion':'jobs.edit','review-promotion':'marketing.draft','approve-promotion':'marketing.approve','manual-promotion':'marketing.publish','candidate-next':'candidates.review','reject-candidate':'candidates.review','toggle-task':'tasks.complete','edit-access':'access.manage','director-access':'access.manage','save-access':'access.manage'};
if(viewAs&&actionCaps[action]&&!can(actionCaps[action])){toast(`Not permitted in this simulation: ${labels[actionCaps[action]]||actionCaps[action]} is not granted.`);return;}
```

Add the exit branch anywhere in the chain:

```js
else if(action==='exit-view-as'){viewAs=null;render();}
```

At the top of the submit handler (after `event.preventDefault()` and resolving `form`), add the same pattern for forms:

```js
const formCaps={'request-form':'jobs.edit','description-form':'jobs.edit','changes-form':'jobs.approve','promotion-form':'marketing.draft','candidate-note-form':'candidates.review','rejection-form':'candidates.review','hire-form':'employment.edit','manual-form':'jobs.publish'};
if(viewAs&&formCaps[form.id]&&!can(formCaps[form.id])){toast('Not permitted in this simulation.');return;}
```

(`application-form` is deliberately absent — the public careers form is open to anyone.)

### Step 7: Filter the overview queue by capability

In `overview()`'s `needs` array (from plan 004), gate each group: hiring-request rows only when `can('jobs.approve')`, promotion rows only when `can('marketing.approve')`, onboarding rows only when `can('tasks.view')`. Also render the `Hiring requests` metric only when `can('jobs.view')` (replace it with `metric('Your access','—','Capabilities are set per company')` when not), and hide the `Configure a director` card's button behind `can('access.manage')` by disabling it via `btn(...,'director-access','','secondary small',!can('access.manage'))`.

Also in `render()`'s reset-demo/topbar: no change — Reset demo stays available (it is a prototype control, not a simulated capability).

**Verify (steps 2–7)**: `node --check prototype/app.js` → exit 0, and the full prior suite still passes as Admin: `npm test -- tests/walkthrough-a.spec.js tests/walkthrough-b.spec.js tests/needs-action.spec.js` → all pass.

### Step 8: New spec tests/view-as.spec.js

Model after `tests/walkthrough-a.spec.js`. Three tests (all start at `/prototype/`):

1. **Finance sees people but not hiring**: select the option containing `Noah Bennett` in `#view-as`; expect `#viewas-banner` visible containing `Viewing as Noah Bennett`; expect nav link `People & access` visible; expect nav links `Hiring workspace` and `Activity` to have count 0 (`page.locator('#navigation a', { hasText: 'Hiring workspace' })` → `toHaveCount(0)`); expect the `All companies` option gone from `#company-select`.
2. **Director can approve; blocked from completing tasks**: select `Alex Morgan`; nav shows `Hiring workspace`; go to it; click `Approve request`; expect badge `Approved` (Director preset has `jobs.approve`). Go to `Onboarding` (Director has `tasks.view`) — with no plans seeded it shows the empty state; instead verify the block path on overview: not applicable — so verify via hiring: click journey step `[data-step="job"]`, click `Publish demo listing`, expect toast containing `Not permitted in this simulation` and badge still `Not published` (Director lacks `jobs.publish`).
3. **Exit returns Admin**: select `Alex Morgan`, then click `Return to Admin` in the banner; expect banner hidden, `All companies` option present again, and `Activity` nav link visible.

**Verify**: `npm test -- tests/view-as.spec.js` → 3 passed.

### Step 9: Full suite

**Verify**: `npm test` → all pass (baseline 4 + needs-action 1 + view-as 3 = 8).

## Test plan

Three new tests per step 8: capability-driven nav filtering, allowed vs blocked actions for the same simulated user, and clean exit. Existing suites double as the regression net proving Admin behavior is unchanged.

## Done criteria

- [ ] `node --check prototype/app.js` exits 0
- [ ] `npm test` exits 0, 8 passed
- [ ] `grep -Fc "exit-view-as" prototype/app.js` → 2 or more (banner button + handler)
- [ ] Admin default view renders identically (walkthrough specs unmodified and green)
- [ ] Only in-scope files modified relative to base branch (`git diff --stat advisor/004-needs-action-queue`)

## STOP conditions

Stop and report back (do not improvise) if:

- The `needs` array from plan 004 is not present in `overview()` (dependency not landed).
- Any pre-existing spec fails twice after your changes — Admin behavior regressions are outside this plan's mandate.
- The gating design above conflicts with a structure you find in the code that the excerpts don't show.

## Maintenance notes

- Gating is *presentation-layer simulation*. The live system needs server-side enforcement; nothing here should be marketed as security. The banner text and existing disclaimers carry that message — keep them.
- Plan 006 builds a self-service overview on top of `viewAs`/`can()`; plan 007 gates a Projects tab with `can('projects.view')`. Keep both helpers top-level.
- `actionCaps`/`formCaps` are the single registry for capability gating — future actions must add themselves there, not inline ad-hoc checks.
