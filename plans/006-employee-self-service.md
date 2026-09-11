# Plan 006: Employee self-service overview when viewing as a person

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat a690d31..HEAD -- prototype/`
> prototype/ will already contain plans 002–005 (fixes, esc() pass, overview
> queue, view-as simulation with `viewAs`, `viewer()`, `can()` helpers) —
> expected, not drift. If `viewAs`/`can()` are absent, STOP: dependency 005
> has not landed.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: LOW
- **Depends on**: plans/005-view-as-simulation.md
- **Category**: direction
- **Planned at**: commit `a690d31`, 2026-09-10

## Why this matters

Employee self-service is the biggest capability gap versus the commercial products the docs benchmark against (Personio, BambooHR, HiBob) — it is the surface an actual team member would touch daily. The blueprint already anticipates it: the preset list includes `Employee` (`docs/hr-system-blueprint.md:48`) and §11 of the core plan proposes "employees access their own permitted information/tasks" (`docs/hr-product-plan.md:247`). After plan 005, "viewing as" a person with few grants shows a nearly empty admin overview — this plan replaces that dead end with a personal workspace: my profile, my onboarding tasks, my access. It gives every one of the 40 seeded people a meaningful home page and completes the Sam story (manager sees work; payroll stays invisible until granted).

## Current state

After plan 005, `prototype/app.js` has:

- `viewAs` (person id or null), `viewer()`, `can(cap)` top-level helpers.
- `overview()` returning the admin dashboard (metrics, needs queue, company grid, walkthrough cards), with queue groups gated by `can()`.
- Data available for a personal view:
  - `state.people[]`: `{id, name, company, title, department, status}` — hired people additionally have `start` and `manager` (`app.js:222` at `a690d31`).
  - `state.onboarding[]`: `{id, job, employeeId, company, name, title, manager, start, tasks:[{id,title,owner,due,critical,done}]}` — `employeeId` links a plan to its person.
  - `state.grants[personId+'|'+companyId]` → `{preset, permissions}`; permission labels in the `labels` map (`app.js:16`).
- Rendering conventions to reuse: `head(eyebrow,title,description)`, `card` markup (`<div class="card"><div class="card-head">…</div><div class="card-body">…</div></div>`), `avatar(name)`, `badge(text,tone)`, `btn(...)`, `.detail-grid` for label/value pairs, `.task` rows (see `onboardingPage`, `app.js:151` at `a690d31`), `.preview-list` for capability lists (see `updateAccessPreview`, `app.js:119`). All dynamic values through `esc()`.
- The click action `toggle-task` (gated by `tasks.complete` in plan 005's `actionCaps`) works from any page since the handler is global and looks up the plan/task by `data-plan`/`data-task` (`app.js:193`).

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Install deps | `npm install` then `npx playwright install chromium` | exit 0 |
| Syntax check | `node --check prototype/app.js` | exit 0 |
| Tests | `npm test` | all prior tests + 2 new pass |

## Scope

**In scope**:
- `prototype/app.js` (one new `selfServiceOverview()` function + a one-line branch in `overview()`)
- `tests/self-service.spec.js` (create)

**Out of scope**: `prototype/index.html`, `prototype/styles.css` (reuse existing classes only), all other pages, all existing specs.

## Git workflow

- Branch from plan 005's result: `git checkout -b advisor/006-employee-self-service advisor/005-view-as-simulation`
- Commit style: `feat: personal self-service overview in view-as mode`
- Do NOT push or open a PR.

## Steps

### Step 1: Branch overview() into the personal view

At the very top of `overview()` add:

```js
if(viewAs)return selfServiceOverview();
```

The admin dashboard below it remains untouched (Admin never has `viewAs` set).

### Step 2: Implement selfServiceOverview()

Add the new function directly after `overview()`. Target shape (dense style, `esc()` everywhere):

```js
function selfServiceOverview(){
  const v=viewer(),g=state.grants[viewAs+'|'+scope]||{preset:'No access',permissions:[]};
  const myPlans=state.onboarding.filter(p=>p.employeeId===viewAs);
  const owned=state.onboarding.filter(inScope).flatMap(p=>p.tasks.filter(t=>!t.done&&t.owner===v.name).map(t=>({plan:p,task:t})));
  return head('MY WORKSPACE',`Welcome, ${esc(v.name.split(' ')[0])}.`,'Your record, your tasks, and what you can do in this company.')+
  `<div class="grid-two"><div>`+
  // My onboarding (only when this person has a plan)
  (myPlans.length?myPlans.map(p=>`<div class="card"><div class="card-head"><div><h2>My onboarding</h2><p>Starts ${esc(p.start)} · ${esc(p.manager)}, Manager</p></div>${badge(p.tasks.some(t=>t.critical&&!t.done)?'In preparation':'Ready for day one',p.tasks.some(t=>t.critical&&!t.done)?'amber':'green')}</div><div class="card-body">${p.tasks.map(t=>`<div class="task ${t.done?'done':''}"><span class="task-status" aria-hidden="true">${t.done?'✓':'○'}</span><div class="row-text"><strong>${esc(t.title)}</strong><small>${esc(t.owner)} · ${esc(t.due)}</small></div>${can('tasks.complete')?btn(t.done?'Reopen':'Mark complete','toggle-task',`data-plan="${p.id}" data-task="${t.id}"`,t.done?'ghost small':'secondary small'):''}</div>`).join('')}</div></div>`).join(''):'')+
  // Tasks I own for others
  (owned.length?`<div class="card"><div class="card-head"><div><h2>Tasks assigned to me</h2><p>Onboarding steps where you are the owner.</p></div>${badge(`${owned.length} open`,'amber')}</div>${owned.map(({plan,task})=>`<div class="list-row"><div class="row-text"><strong>${esc(task.title)}</strong><small>For ${esc(plan.name)} · ${esc(task.due)}</small></div>${can('tasks.complete')?btn('Mark complete','toggle-task',`data-plan="${plan.id}" data-task="${task.id}"`):''}</div>`).join('')}</div>`:'')+
  ((!myPlans.length&&!owned.length)?`<div class="card"><div class="empty"><h3>Nothing waiting on you.</h3><p>Tasks assigned to you and your own onboarding will appear here.</p></div></div>`:'')+
  `</div><div>`+
  // My profile
  `<div class="card"><div class="card-head"><h2>My profile</h2></div><div class="card-body"><div class="person-cell">${avatar(v.name)}<div><strong>${esc(v.name)}</strong><small>${esc(v.title)} · ${esc(v.department)}</small></div></div><dl class="detail-grid gap-top"><div><dt>Employing company</dt><dd>${esc(company(v.company).name)}</dd></div><div><dt>Status</dt><dd>${badge(v.status,v.status==='Active'?'green':'blue')}</dd></div>${v.start?`<div><dt>Start date</dt><dd>${esc(v.start)}</dd></div>`:''}${v.manager?`<div><dt>Manager</dt><dd>${esc(v.manager)}</dd></div>`:''}</dl></div></div>`+
  // My access in the selected company
  `<div class="card"><div class="card-head"><div><h2>My access here</h2><p>${esc(company(scope).name)} · preset: ${esc(g.preset)}</p></div></div><div class="card-body">${g.permissions.length?`<ul class="preview-list">${g.permissions.map(id=>`<li>${labels[id]}</li>`).join('')}</ul>`:'<p class="small-copy">No capabilities granted in this company.</p>'}<div class="inline-note gap-top">Access is granted by your admin per company. This simulation shows exactly what your grant allows.</div></div></div>`+
  `</div></div>`;
}
```

Adjust freely to keep `node --check` happy, but preserve: the three information blocks (onboarding/owned tasks, profile, access), the `can('tasks.complete')` gate on task buttons, and `esc()` on all person/company-derived values.

**Verify**: `node --check prototype/app.js` → exit 0.

### Step 3: New spec

Create `tests/self-service.spec.js` (model after `tests/view-as.spec.js`). Two tests:

1. **No-access person gets a personal page, not a dead dashboard**: goto `/prototype/`; select `Oliver Reed` in `#view-as` (Company A, seeded preset `No access`); expect heading `Welcome, Oliver.`; expect `My profile` card with `Software Engineer`; expect `My access here` card containing `No capabilities granted in this company.`; expect the text `Needs a decision` to have count 0.
2. **Hired employee sees their onboarding read-only**: run the abbreviated hire path (as in `tests/walkthrough-b.spec.js`: approve → advance Jamie Taylor: `Prepare offer` → `Record acceptance` → `Confirm hire` → department `Operations` → `Confirm hire & create plan`). Then select the `#view-as` option containing `Jamie Taylor`; expect `My onboarding` card with 5 `.task` rows and badge `In preparation`; expect zero `Mark complete` buttons inside that card (a fresh hire's grant is `No access`, so no `tasks.complete`).

**Verify**: `npm test -- tests/self-service.spec.js` → 2 passed.

### Step 4: Full suite

**Verify**: `npm test` → all pass (10 total: 4 baseline + 1 needs-action + 3 view-as + 2 self-service).

## Test plan

Per step 3. The view-as spec from plan 005 keeps covering the gating; these two tests cover the personal rendering for the two seed archetypes (never-hired person, fresh hire with an onboarding plan).

## Done criteria

- [ ] `node --check prototype/app.js` exits 0
- [ ] `npm test` exits 0, 10 passed
- [ ] `grep -Fc "selfServiceOverview" prototype/app.js` → 2 (definition + call)
- [ ] Admin overview unchanged (walkthrough + needs-action specs untouched and green)
- [ ] Only in-scope files modified relative to base branch (`git diff --stat advisor/005-view-as-simulation`)

## STOP conditions

Stop and report back (do not improvise) if:

- `viewAs`, `viewer()`, or `can()` do not exist in `prototype/app.js` (plan 005 not landed).
- Test 2's hire path fails before the self-service assertion (walkthrough-b regression — report, don't patch around it).
- `npm test` fails twice after your changes.

## Maintenance notes

- Plan 007 adds a "My projects" card into `selfServiceOverview()` — keep the function's `grid-two` structure so a card can be appended to the right column.
- The `owned` list matches tasks by owner *name* — fine for seeded data, but a known modeling shortcut; the blueprint's real model assigns tasks to identities. Flag this in any future round that adds task assignment.
