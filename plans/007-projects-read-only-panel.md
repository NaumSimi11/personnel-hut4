# Plan 007: Read-only Projects panel (simulated external sync) with a projects.view permission

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat a690d31..HEAD -- prototype/`
> prototype/ will already contain plans 002–006. If `can()` (plan 005) or
> `selfServiceOverview()` (plan 006) are absent, STOP: dependencies not landed.
> Line references are from `a690d31`; match on content.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MED (changes the seed shape — requires a storage version bump)
- **Depends on**: plans/006-employee-self-service.md
- **Category**: direction
- **Planned at**: commit `a690d31`, 2026-09-10

## Why this matters

The maintainer's stated scenario: a manager should "see on what projects they are working… but cannot see the payrolls yet." Project work lives in an external tool (Zoho Projects), and the docs already define the pattern for exactly this: the external system owns the facts; the portal shows a read-only view with source and freshness, never a competing editor (`docs/hr-product-plan.md:255-261`, the leave-system integration). This plan adds that read-only Projects surface to the prototype with synthetic "synced" data, a new `projects.view` capability wired into the existing grant model, a Projects tab on the company profile, and a "My projects" card in self-service. No external calls — everything simulated and labeled, per the prototype's rules (`docs/design-round-01.md:19`).

## Current state

`prototype/app.js` facts (line numbers from `a690d31`):

- Storage key and version gate:
```js
// app.js:3
const KEY = 'personnel-design-round-01-v1';
// app.js:50 (end of seed())
return {version:1,companies,people,grants,jobs,onboarding:[],activity:[]};
// app.js:53
try { const saved=JSON.parse(localStorage.getItem(KEY));state=saved?.version===1?saved:seed(); } catch {state=seed();}
```
- Permission groups (`app.js:7-15`) are `['Group title',[[id,label,sensitive?],...]]` entries; `labels` is derived (`app.js:16`); `dependencies` (`app.js:17-26`) and `presets` (`app.js:27-35`) reference ids. Presets at `a690d31`: `Company Director`, `Company HR`, `Finance`, `IT`, `Marketing`, `Hiring Manager`, `No access`, `Custom`.
- `seed()` (`app.js:36-51`) builds `companies` (ids `c1`–`c4`), `people` (ids `p{i}-{j}`, j=0..9 per company), `grants`, `jobs`.
- Company profile tabs (`app.js:91`, gated by plan 005): `[['overview','Overview'],['people','People'],['access','Access'],['hiring','Hiring'],['integrations','Integrations']]` with per-tab bodies assigned via `if(companyTab==='…')body=…`.
- Reusable markup: `.channel` blocks with `.channel-top` (see the integrations tab, `app.js:96`), `badge()`, `.person-cell`, `avatar()`, `.inline-note`, `.source`. All dynamic values through `esc()`.
- Plan 005 helpers: `can(cap)`, `pageCaps`, tab gating in `companyPage`. Plan 006: `selfServiceOverview()` with a right-hand column of cards.
- Reset handler (`app.js:233`) reseeds via `state=seed()`.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Install deps | `npm install` then `npx playwright install chromium` | exit 0 |
| Syntax check | `node --check prototype/app.js` | exit 0 |
| Tests | `npm test` | all prior tests + 2 new pass |

## Scope

**In scope**:
- `prototype/app.js`
- `tests/projects.spec.js` (create)

**Out of scope**: `prototype/index.html`, `prototype/styles.css` (reuse existing classes), `docs/`, existing specs, any real network/integration code.

## Git workflow

- Branch from plan 006's result: `git checkout -b advisor/007-projects-read-only-panel advisor/006-employee-self-service`
- Commit style: `feat: read-only projects panel with projects.view capability`
- Do NOT push or open a PR.

## Steps

### Step 1: Version bump

Because the seed shape changes, stale stored demo data must be discarded (the docs authorize this: local storage holds "fictional demo data only", `docs/design-round-01.md:54`):

- `app.js:3` → `const KEY = 'personnel-design-round-01-v2';`
- seed return → `version:2` and the load gate → `saved?.version===2`.

**Verify**: `grep -c "design-round-01-v2" prototype/app.js` → 1 and `grep -Fc "version===2" prototype/app.js` → 1.

### Step 2: Permission and presets

In `groups`, insert a new group before `Administration`:

```js
['Projects & work', [['projects.view','View project assignments (read-only)']]],
```

No entry in `dependencies` (it is an independent read-only capability, mirroring the leave-indicator pattern). Add `'projects.view'` to the `Company Director`, `Company HR`, and `Hiring Manager` preset arrays (the manager archetype from the maintainer's scenario). Do NOT add it to `Finance`, `IT`, `Marketing`, or `No access`.

**Verify**: `node --check prototype/app.js` → exit 0.

### Step 3: Seed synthetic project data

In `seed()`, after `jobs` is built, add two projects per company with members drawn from that company's people (deterministic, no randomness):

```js
const projectNames=[['Website relaunch','Internal tools cleanup'],['Retail rollout','Supplier portal'],['Mobile app v2','Data warehouse'],['Brand refresh','Logistics automation']];
const projects=companies.flatMap((company,i)=>projectNames[i].map((name,k)=>({id:`pr${i}-${k}`,company:company.id,name,status:k===0?'Active':'On hold',source:'Zoho Projects (sample)',lastSync:'2026-09-10T08:00:00Z',members:[people[i*10+2].id,people[i*10+4].id,people[i*10+8].id].slice(0,k===0?3:2)})));
```

Include `projects` in the returned state object (alongside `jobs`).

**Verify**: `node --check prototype/app.js` → exit 0.

### Step 4: Projects tab on the company profile

In `companyPage`, add `['projects','Projects']` to the tabs array between `hiring` and `integrations`, gated (per plan 005's tab gating) by `can('projects.view')`. Add its body:

```js
if(companyTab==='projects')body=`<div class="card"><div class="card-head"><div><h2>Projects</h2><p>Read-only view synced from your project system (simulated).</p></div>${badge('Zoho Projects (sample)','blue')}</div><div class="card-body">${state.projects.filter(inScope).map(pr=>`<div class="channel"><div class="channel-top"><h3>${esc(pr.name)}</h3>${badge(pr.status,pr.status==='Active'?'green':'gray')}</div><p>${pr.members.length} assigned · Last sync ${new Date(pr.lastSync).toLocaleString()}</p>${pr.members.map(id=>{const m=person(id);return m?`<div class="person-cell" style="margin-bottom:8px">${avatar(m.name)}<div><strong>${esc(m.name)}</strong><small>${esc(m.title)}</small></div></div>`:''}).join('')}</div>`).join('')||'<div class="empty">No projects synced for this company.</div>'}<div class="inline-note">Project facts stay in the external system. This panel is read-only; assignments, deadlines, and budgets are not edited here.</div></div></div>`;
```

**Verify**: `node --check prototype/app.js` → exit 0.

### Step 5: "My projects" card in self-service

In `selfServiceOverview()` (plan 006), append to the right-hand column (after the "My access here" card):

```js
+(can('projects.view')||state.projects.some(pr=>pr.members.includes(viewAs))?`<div class="card"><div class="card-head"><h2>My projects</h2></div><div class="card-body">${state.projects.filter(pr=>pr.members.includes(viewAs)).map(pr=>`<div class="channel"><div class="channel-top"><h3>${esc(pr.name)}</h3>${badge(pr.status,pr.status==='Active'?'green':'gray')}</div><p class="source">${esc(pr.source)}</p></div>`).join('')||'<p class="small-copy">No project assignments synced.</p>'}</div></div>`:'')
```

(A person always sees their *own* assignments; `projects.view` governs seeing the company-wide panel.)

**Verify**: `node --check prototype/app.js` → exit 0.

### Step 6: New spec

Create `tests/projects.spec.js` (model after `tests/view-as.spec.js`). Two tests:

1. **Admin sees the company panel**: goto `/prototype/#company`; click `Open company profile →` on the Company A card; click the `Projects` tab; expect cards `Website relaunch` (badge `Active`) and `Internal tools cleanup` (badge `On hold`); expect the text `Zoho Projects (sample)` and `read-only` note visible.
2. **Capability gates the tab, self-service shows own assignments**: goto `/prototype/`; select `Noah Bennett` in `#view-as` (Finance — no `projects.view`); via `#company-select` stay on Company A; navigate to the company page via the nav link `Company profiles`; expect no `Projects` tab (`page.locator('.tab', { hasText: 'Projects' })` → count 0). Then select `Oliver Reed` in `#view-as` (he is `people[2]` of Company A, a seeded member of `Website relaunch`); expect the self-service overview's `My projects` card to contain `Website relaunch`. Then select `Alex Morgan` (Director, has `projects.view`), open `Company profiles` → expect the `Projects` tab present.

**Verify**: `npm test -- tests/projects.spec.js` → 2 passed.

### Step 7: Full suite

**Verify**: `npm test` → all pass (12 total).

## Test plan

Per step 6: the admin panel content, the capability gate on the tab, and the own-assignments card. Existing suites confirm the version bump doesn't break flows (every test starts from a fresh context, so they always exercise the new seed).

## Done criteria

- [ ] `node --check prototype/app.js` exits 0
- [ ] `npm test` exits 0, 12 passed
- [ ] `grep -c "projects.view" prototype/app.js` → ≥ 5 (group, 3 presets, tab gate / self-service)
- [ ] `grep -c "design-round-01-v1" prototype/app.js` → 0
- [ ] Only in-scope files modified relative to base branch (`git diff --stat advisor/006-employee-self-service`)

## STOP conditions

Stop and report back (do not improvise) if:

- `can()` or `selfServiceOverview()` are missing (dependencies 005/006 not landed).
- The tabs array or integrations-tab markup doesn't match the excerpts (drift).
- `npm test` fails twice after your changes.

## Maintenance notes

- The panel deliberately mirrors the leave-system integration contract (read-only, source-labeled, freshness shown). When a real Zoho Projects connection is designed, keep this UI and swap the data source; statuses to design are in `docs/hr-system-blueprint.md:121` (Not connected / Authorization required / Connected / Sync issue / Disconnected).
- Storage version is now 2; any future seed-shape change bumps to v3 (both the KEY suffix and the `version` field — they must move together).
- `docs/design-round-01.md` does not yet describe rounds 004–007 features; a docs refresh is deferred deliberately (one doc update after the round is reviewed, not seven partial edits).
