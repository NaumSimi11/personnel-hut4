# Plan 004: Unify the Overview "Needs a decision" card into a cross-workflow action queue

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat a690d31..HEAD -- prototype/app.js`
> prototype/app.js will already contain plans 002–003 (navigation guard,
> robustness fixes, esc() wrapping of company names) — expected, not drift.
> Line numbers below are from `a690d31` and will have shifted slightly; match
> on content. Any other mismatch with the excerpts is a STOP condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: plans/003-consistent-html-escaping.md
- **Category**: direction
- **Planned at**: commit `a690d31`, 2026-09-10

## Why this matters

The product's stated core pitch is one queue of pending handoffs: "Every hiring/onboarding item has an owner and next action; HR sees overdue or blocked handoffs in one queue" (`docs/hr-system-blueprint.md:137`), and the blueprint's Home page lists "My tasks, Approvals" (`docs/hr-system-blueprint.md:17`). The prototype's Overview card "Needs a decision" only shows submitted hiring requests — promotional copy sitting "In review" and unmet critical onboarding tasks never surface anywhere aggregated. All the data is already in `state`; this plan makes the card live up to the pitch.

## Current state

`prototype/app.js`, `overview()` — the card today (~lines 79–86; after plan 003 the `company(...)` interpolations inside it are wrapped in `esc()`):

```js
function overview(){
  const people=state.people.filter(inScope), jobs=state.jobs.filter(inScope), plans=state.onboarding.filter(inScope);
  ...
  `... <div class="grid-two"><div><div class="card"><div class="card-head"><div><h2>Needs a decision</h2><p>Clear ownership. One next action.</p></div>${badge('Hiring','green')}</div>${jobs.filter(j=>j.request==='Submitted').map((j,i)=>`<div class="list-row"><span class="list-num">0${i+1}</span><div class="row-text"><strong>${esc(j.title)}</strong><small>${esc(company(j.company).name)} · Requested by ${esc(j.manager)}</small></div>${btn('Review request','open-job',`data-id="${j.id}"`)}</div>`).join('')||'<div class="empty">All hiring requests have been reviewed.</div>'}</div> ...`
```

Relevant data shapes (`seed()`, ~line 49, and the hire handler, ~lines 220–229):

- `job.request`: `'Submitted' | 'Approved' | 'Changes requested'`
- `job.promotion.status`: `'Not requested' | 'Requested' | 'Draft' | 'In review' | 'Approved' | 'Published manually'`
- `state.onboarding[]`: `{id, job, employeeId, company, name, title, manager, start, tasks:[{id,title,owner,due,critical,done}]}`

Existing click actions the queue rows reuse (~lines 159–192): `open-job` (`data-id`, jumps to hiring request step), `open-onboarding` (`data-id`, navigates + scrolls to the plan card). There is no action that jumps straight to the promotion step; this plan adds `open-promotion`.

Row/list styling conventions: `.list-row`, `.list-num`, `.row-text`, `btn(label, action, data)` — see the excerpt above; reuse them exactly.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Install deps | `npm install` then `npx playwright install chromium` | exit 0 |
| Syntax check | `node --check prototype/app.js` | exit 0 |
| Tests | `npm test` | all baseline tests + 1 new test pass |

## Scope

**In scope**:
- `prototype/app.js` (the `overview()` queue and one new click action)
- `tests/needs-action.spec.js` (create)

**Out of scope**: `prototype/index.html`, `prototype/styles.css`, all other pages/cards in `overview()` (metrics, company grid, walkthrough card), `docs/`.

## Git workflow

- Branch from plan 003's result: `git checkout -b advisor/004-needs-action-queue advisor/003-consistent-html-escaping`
- Commit style: `feat: aggregate hiring, promotion and onboarding items into the overview queue`
- Do NOT push or open a PR.

## Steps

### Step 1: Build the queue rows

In `overview()`, immediately after the existing `const people=..., jobs=..., plans=...` line, compose the queue (match the file's dense style; all dynamic values through `esc()`):

```js
const needs=[
  ...jobs.filter(j=>j.request==='Submitted').map(j=>({title:esc(j.title),sub:`${esc(company(j.company).name)} · Hiring request by ${esc(j.manager)}`,action:btn('Review request','open-job',`data-id="${j.id}"`)})),
  ...jobs.filter(j=>j.promotion.status==='In review').map(j=>({title:`Promotion copy: ${esc(j.title)}`,sub:`${esc(company(j.company).name)} · Awaiting content approval`,action:btn('Review copy','open-promotion',`data-id="${j.id}"`)})),
  ...plans.filter(p=>p.tasks.some(t=>t.critical&&!t.done)).map(p=>({title:`Onboarding: ${esc(p.name)}`,sub:`${esc(company(p.company).name)} · ${p.tasks.filter(t=>t.critical&&!t.done).length} critical task(s) before start`,action:btn('Open plan','open-onboarding',`data-id="${p.id}"`)}))
];
```

### Step 2: Render the queue in the existing card

Replace the card's row-mapping expression (the `${jobs.filter(j=>j.request==='Submitted').map((j,i)=>...).join('')||'<div class="empty">All hiring requests have been reviewed.</div>'}` part) with:

```js
${needs.map((n,i)=>`<div class="list-row"><span class="list-num">${String(i+1).padStart(2,'0')}</span><div class="row-text"><strong>${n.title}</strong><small>${n.sub}</small></div>${n.action}</div>`).join('')||'<div class="empty">Nothing needs a decision right now.</div>'}
```

Also change the card badge from `${badge('Hiring','green')}` to `${badge(`${needs.length} open`,needs.length?'amber':'green')}` and the card subtitle `<p>Clear ownership. One next action.</p>` to `<p>Hiring approvals, content reviews, and readiness gaps in one queue.</p>`.

**Verify**: `node --check prototype/app.js` → exit 0.

### Step 3: Add the open-promotion action

In the click handler chain (next to `open-job`, ~line 162), add:

```js
else if(action==='open-promotion'){jobId=id;scope=state.jobs.find(j=>j.id===id).company;hiringStep='promotion';navigate('hiring');}
```

**Verify**: `node --check prototype/app.js` → exit 0.

### Step 4: New spec

Create `tests/needs-action.spec.js` (model after `tests/walkthrough-a.spec.js` structure) with one test:

1. goto `/prototype/#hiring`; click `Approve request`; click the journey step `[data-step="promotion"]`; click `Request promotion`; click `Submit for review`.
2. goto `/prototype/#overview` (or click the Overview nav link); expect the queue card to contain `Promotion copy: Operations Coordinator` and the remaining seeded hiring-request rows (e.g. `Product Designer`).
3. Click `Review copy`; expect the hiring page promotion step visible with badge `In review`.

**Verify**: `npm test -- tests/needs-action.spec.js` → 1 passed.

### Step 5: Full suite

**Verify**: `npm test` → all pass (baseline 4 + 1 new). Note: walkthrough-a asserts on activity text, not on the overview card, so it is unaffected; if any baseline test asserts the old empty-state string `All hiring requests have been reviewed.`, that would be a STOP condition — check first with `grep -rn "All hiring requests" tests/`.

## Test plan

One new Playwright test (step 4) covering: promotion-in-review surfaces on Overview, and its row button deep-links to the promotion step. The onboarding-gap row is exercised indirectly: after walkthrough B's hire, the queue shows the readiness row — optional extra assertion if cheap, not required.

## Done criteria

- [ ] `node --check prototype/app.js` exits 0
- [ ] `npm test` exits 0 (5 tests)
- [ ] `grep -Fc "open-promotion" prototype/app.js` → 2 (the btn and the handler)
- [ ] Only in-scope files modified relative to the base branch (`git diff --stat advisor/003-consistent-html-escaping`)

## STOP conditions

Stop and report back (do not improvise) if:

- The `overview()` card excerpt cannot be located (drift beyond plans 002–003).
- `grep -rn "All hiring requests" tests/` shows a baseline test depending on the removed empty-state text.
- `npm test` fails twice after your changes.

## Maintenance notes

- Plan 005 (view-as simulation) will filter these queue rows by the simulated user's capabilities; keep the three-part `needs` array structure — it's what 005 hooks into.
- When more workflows land (offboarding, documents), extend `needs` with the same `{title, sub, action}` shape rather than adding parallel cards.
