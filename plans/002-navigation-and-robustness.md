# Plan 002: Fix the double render on navigation and three robustness gaps

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat a690d31..HEAD -- prototype/app.js`
> This plan expects prototype/app.js unchanged from `a690d31` EXCEPT possibly
> by advisor plan 001 (which does not touch prototype/). Compare the "Current
> state" excerpts against the live code before proceeding; on a content
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: plans/001-verification-baseline.md
- **Category**: bug
- **Planned at**: commit `a690d31`, 2026-09-10

## Why this matters

Every in-app navigation renders the page twice: `navigate()` calls `render()` AND sets `location.hash`, whose `hashchange` listener renders again. The second render replaces the whole `#main` DOM, which aborts the smooth `scrollIntoView` used by "Open onboarding plan" — a demo path in the design walkthrough. Three smaller gaps make the prototype brittle for the next design round: a hardcoded company count of `4`, `getJob()` returning `undefined` (crashing `hiringPage`) if a scoped company ever has zero jobs, and an activity log that grows without bound in localStorage.

## Current state

All in `prototype/app.js` (line numbers from commit `a690d31`; a vanilla-JS, single-file app with global state and full re-render per action). The repo's convention is dense single-line statements; match it.

`app.js:71` — navigate:
```js
function navigate(target){page=target;query='';location.hash=target;render();}
```

`app.js:234` — hashchange listener (renders unconditionally, so every `navigate()` renders twice):
```js
window.addEventListener('hashchange',()=>{page=location.hash.slice(1)||'overview';query='';render();});
```

`app.js:192` — the scroll that the double render aborts:
```js
else if(action==='open-onboarding'){navigate('onboarding');document.getElementById('plan-'+id)?.scrollIntoView({behavior:'smooth',block:'start'});}
```

`app.js:60` — getJob can return `undefined` when no job is in scope:
```js
const getJob = () => state.jobs.find(j=>j.id===jobId&&inScope(j))||state.jobs.find(inScope);
```

`app.js:134-135` — hiringPage dereferences it immediately:
```js
function hiringPage(){
  const j=getJob();jobId=j.id;
```

`app.js:83` — hardcoded company count in the overview metric:
```js
${metric('Companies',scope==='all'?4:1,scope==='all'?'One shared holding workspace':'Company-scoped view')}
```

`app.js:63` — unbounded activity growth:
```js
function audit(companyId,message){state.activity.unshift({company:companyId,message,at:new Date().toISOString()});}
```

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Install deps | `npm install` then `npx playwright install chromium` | exit 0 (fresh worktrees lack node_modules) |
| Syntax check | `node --check prototype/app.js` | exit 0 |
| Tests | `npm test` | all 4 baseline tests pass |

## Scope

**In scope**:
- `prototype/app.js`

**Out of scope** (do NOT touch):
- `prototype/index.html`, `prototype/styles.css`
- `tests/`, `playwright.config.js`, `package.json`
- `index.html`, `hr-system.html`, `docs/`

## Git workflow

- Branch from plan 001's result: `git checkout -b advisor/002-navigation-and-robustness advisor/001-verification-baseline`
- Commit style: conventional commits, e.g. `fix: render once per navigation and guard empty job scope`
- Do NOT push or open a PR.

## Steps

### Step 1: Render once per navigation

Replace the `hashchange` listener (`app.js:234`) so it no-ops when the hash already matches the current page (which is the case right after `navigate()` ran):

```js
window.addEventListener('hashchange',()=>{const target=location.hash.slice(1)||'overview';if(target===page)return;page=target;query='';render();});
```

Leave `navigate()` unchanged — it must keep rendering synchronously so `open-onboarding`'s `scrollIntoView` finds its element; with this guard the later `hashchange` no longer re-renders and the smooth scroll survives.

**Verify**: `node --check prototype/app.js` → exit 0.

### Step 2: Guard hiringPage against an empty job scope

In `hiringPage()` (`app.js:134-135`), after `const j=getJob();` and before `jobId=j.id;`, return an empty state when `j` is undefined:

```js
const j=getJob();if(!j)return head('RECRUITMENT','No hiring workspaces in this scope.','Select another company or reset the demo to see the sample roles.');
jobId=j.id;
```

**Verify**: `node --check prototype/app.js` → exit 0.

### Step 3: Derive the company count

In `overview()` (`app.js:83`), replace the hardcoded `4`:

```js
${metric('Companies',scope==='all'?state.companies.length:1,scope==='all'?'One shared holding workspace':'Company-scoped view')}
```

**Verify**: `grep -Fn "scope==='all'?4:1" prototype/app.js` → no matches.

### Step 4: Cap the activity log

In `audit()` (`app.js:63`), cap the log at 200 entries after the unshift:

```js
function audit(companyId,message){state.activity.unshift({company:companyId,message,at:new Date().toISOString()});if(state.activity.length>200)state.activity.length=200;}
```

**Verify**: `node --check prototype/app.js` → exit 0.

### Step 5: Full suite

**Verify**: `npm test` → all 4 tests pass (the baseline suite asserts navigation-heavy flows including `Open onboarding plan` paths, walkthrough B).

## Test plan

No new spec file. The existing walkthrough suites exercise every changed code path: walkthrough B ends on the Onboarding page after navigation; the overview metric and activity log render on every walkthrough A run. The scroll fix is verified manually by the reviewer (click "Open onboarding plan" from the hiring handoff step; the plan card scrolls into view) because a viewport assertion on a short page passes trivially either way.

## Done criteria

- [ ] `node --check prototype/app.js` exits 0
- [ ] `npm test` exits 0, 4 passed
- [ ] `grep -Fn "scope==='all'?4:1" prototype/app.js` → no matches
- [ ] `grep -Fc "if(target===page)return" prototype/app.js` → 1
- [ ] Only `prototype/app.js` modified relative to the base branch (`git diff --stat advisor/001-verification-baseline`)

## STOP conditions

Stop and report back (do not improvise) if:

- Any "Current state" excerpt does not match the live file content.
- `npm test` fails after your change twice in a row (report which test and the output — the baseline characterizes current behavior, so a failure means the fix changed observable behavior beyond the intent).
- Branch `advisor/001-verification-baseline` does not exist.

## Maintenance notes

- Plan 005 (view-as simulation) touches `render()` and the nav; the single-render guarantee must survive it — anything calling `navigate()` may rely on synchronous post-render DOM access.
- The 200-entry activity cap is a demo bound, not a product decision; the blueprint's real audit store has its own retention requirements.
