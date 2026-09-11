# Plan 001: Establish a Playwright smoke-test baseline for the prototype

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat a690d31..HEAD -- prototype/`
> If any prototype file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: LOW
- **Depends on**: none
- **Category**: tests
- **Planned at**: commit `a690d31`, 2026-09-10

## Why this matters

The repo has zero automated verification — no tests, no lint, no typecheck. Every other plan in `plans/` changes `prototype/app.js`, and without a baseline any regression ships silently into the stakeholder demo. The design doc `docs/design-round-01.md` contains two step-by-step walkthroughs (A: configure a director's access; B: hiring request → hired employee → onboarding) that are effectively executable specs. This plan encodes them as Playwright tests. **These are characterization tests: they must pass against the current code unmodified. Do not change anything in `prototype/`.**

## Current state

- The prototype is a static vanilla-JS app: `prototype/index.html`, `prototype/app.js`, `prototype/styles.css`. No package.json exists anywhere in the repo. No build step; served statically.
- `README.md` documents serving with `python3 -m http.server 8000 --bind 127.0.0.1` from the repo root; the prototype lives at `/prototype/`.
- State persists to localStorage under key `personnel-design-round-01-v1` (`prototype/app.js:3`).
- `.gitignore` currently contains only:

```
.DS_Store
.env
.env.*
!.env.example
*.log
__pycache__/
```

Facts about the app the tests rely on (verified against `prototype/app.js` at `a690d31`):

- Navigation is hash-based: `#overview`, `#company`, `#people`, `#hiring`, `#onboarding`, `#activity` (`app.js:73`). Loading `/prototype/#hiring` opens the hiring page directly (`app.js:54`).
- Overview has a button with text `Configure a director` (`app.js:86`) that opens the `<dialog id="editor">` access editor for Alex Morgan (Company A's director).
- The access editor renders permission checkboxes as `input[data-permission="<id>"]` (`app.js:114`), a company select `#access-company` with values `c1`–`c4`, a preset select `#access-preset`, a preview panel `#access-preview`, group counters `[data-group-count="<group title>"]`, and a save button `[data-action="save-access"]` which is disabled until the draft differs from the baseline.
- Checking `salary.propose` auto-checks its dependency `salary.view`; unchecking `salary.view` cascade-unchecks `salary.propose` (`app.js:123-129`).
- The preview panel shows the literal text `Individual salaries remain hidden.` while `salary.view` is not granted (`app.js:119`).
- Saving shows a toast `#toast` containing `Updated Alex Morgan` and writes an activity entry; the Activity page lists it including text like `Added: View company payroll totals` (`app.js:171`).
- Hiring page: default job is `j0` (Company A · Operations Coordinator). Buttons: `Approve request`; journey step buttons `[data-action="hiring-step"][data-step="job"]` etc.; `Publish demo listing` (enabled only after approval); `Preview careers page` opens a modal with `#applicant-name` input and a `Submit demo application` button (enabled only while the careers channel is `Demo live`).
- Candidate cards have class `.candidate`. Seeded Company A candidates: `Jamie Taylor` (stage `Interview`) and `Robin Lane` (stage `New`). The advance button label depends on stage: Interview → `Prepare offer`, Offer → `Record acceptance`, Offer accepted → `Confirm hire` (`app.js:143`).
- `Confirm hire` opens a form `#hire-form` with a required `#hire-department` select (empty by default) and a submit button `Confirm hire & create plan`; a `Cancel` button closes without creating anything (`app.js:146-149`).
- After a confirmed hire, the handoff step and the Onboarding page show a plan card (`.card[id^="plan-"]`) with 5 tasks (4 critical) and badge `Needs preparation` until all critical tasks are done, then `Ready for day one` (`app.js:151`). Task buttons: `Mark complete` / `Reopen`.
- The app uses `confirm()` for the reset button and for discarding unsaved editor changes — Playwright auto-dismisses `confirm()` by default, which cancels those actions. The tests below avoid needing `confirm()` except where noted.
- Toast auto-hides after 4.5s (`app.js:61`).

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Install deps | `npm install` (repo root) | exit 0, creates `node_modules/`, `package-lock.json` |
| Install browser | `npx playwright install chromium` | exit 0 |
| Run tests | `npm test` | all tests pass |
| Syntax check | `node --check prototype/app.js` | exit 0 (sanity that prototype is untouched/parseable) |

Note: `python3` must be on PATH (the Playwright webServer uses it). Verify with `python3 --version` before starting.

## Scope

**In scope** (the only files you may create/modify):
- `package.json` (create, repo root)
- `package-lock.json` (created by npm)
- `playwright.config.js` (create, repo root)
- `tests/walkthrough-a.spec.js` (create)
- `tests/walkthrough-b.spec.js` (create)
- `.gitignore` (append entries)

**Out of scope** (do NOT touch):
- Anything under `prototype/` — these are characterization tests; if a test can only pass by changing the app, the test is wrong or you hit a STOP condition.
- `index.html`, `hr-system.html`, `docs/`, `README.md`.

## Git workflow

- Branch: create `advisor/001-verification-baseline` from the current HEAD: `git checkout -b advisor/001-verification-baseline`
- Commit style: conventional commits, e.g. `test: add Playwright smoke tests for prototype walkthroughs A and B`
- Do NOT push or open a PR.

## Steps

### Step 1: Create package.json and install Playwright

Create `package.json` at the repo root:

```json
{
  "name": "personnel-prototype",
  "private": true,
  "scripts": {
    "test": "playwright test"
  },
  "devDependencies": {
    "@playwright/test": "^1.48.0"
  }
}
```

Run `npm install`, then `npx playwright install chromium`.

**Verify**: `npx playwright --version` → prints a version, exit 0.

### Step 2: Add gitignore entries

Append to `.gitignore`:

```
node_modules/
test-results/
playwright-report/
```

**Verify**: `git status --short` shows `.gitignore` modified and does NOT list `node_modules/`.

### Step 3: Create playwright.config.js

```js
// @ts-check
const { defineConfig } = require('@playwright/test');

module.exports = defineConfig({
  testDir: './tests',
  timeout: 30000,
  use: { baseURL: 'http://127.0.0.1:8317' },
  webServer: {
    command: 'python3 -m http.server 8317 --bind 127.0.0.1',
    url: 'http://127.0.0.1:8317/prototype/',
    reuseExistingServer: true
  }
});
```

**Verify**: `npx playwright test --list` → exits 0 (no tests yet is fine; must not error on config).

### Step 4: Write tests/walkthrough-a.spec.js (access editor)

Cover Walkthrough A from `docs/design-round-01.md:23-32`. Each test starts fresh (Playwright's per-test context isolates localStorage). Required tests:

1. **Dependency preview and save**: goto `/prototype/`; click `Configure a director`; expect `#editor` visible and heading contains `Alex`; check `[data-permission="payroll.summary"]`; expect `[data-permission="salary.view"]` NOT checked; expect `#access-preview` to contain `Individual salaries remain hidden.`; click `[data-action="save-access"]`; expect `#toast` to contain `Updated Alex Morgan`; click the `Activity` nav link; expect page body to contain `Added: View company payroll totals`.
2. **Independent per-company grants**: goto `/prototype/`; click `Configure a director`; expect `[data-group-count="Employee records"]` to have text `1/4` (Director preset grants only `people.view` in that group); select `c2` in `#access-company`; expect `#access-preview` to contain `No access to this company`; select `c1` again; expect `[data-group-count="Employee records"]` back to `1/4`. (Switching with no unsaved edits does not trigger `confirm()`.)
3. **Dependency cascade on removal**: goto `/prototype/`; click `Configure a director`; check `[data-permission="salary.propose"]`; expect `[data-permission="salary.view"]` checked automatically; uncheck `[data-permission="salary.view"]`; expect `[data-permission="salary.propose"]` unchecked.

Structural pattern:

```js
// @ts-check
const { test, expect } = require('@playwright/test');

test.beforeEach(async ({ page }) => {
  await page.goto('/prototype/');
});

test('enabling payroll totals leaves salary view off and previews it', async ({ page }) => {
  await page.getByRole('button', { name: 'Configure a director' }).click();
  const dialog = page.locator('#editor');
  await expect(dialog).toBeVisible();
  await dialog.locator('[data-permission="payroll.summary"]').check();
  // ...assertions per above
});
```

**Verify**: `npm test -- tests/walkthrough-a.spec.js` → 3 passed.

### Step 5: Write tests/walkthrough-b.spec.js (hiring flow)

Cover Walkthrough B from `docs/design-round-01.md:34-45` as one end-to-end test plus assertions inline (a single long test is acceptable here; it mirrors the doc):

1. goto `/prototype/#hiring`; expect heading `One role. Every handoff connected.`
2. Click `Approve request`; expect a badge with text `Approved`.
3. Click the journey button `[data-step="job"]`; click `Publish demo listing`; expect badge `Demo live`.
4. Click `Preview careers page`; fill `#applicant-name` with `Test Applicant`; click `Submit demo application`; expect the candidates step to show a `.candidate` card containing `Test Applicant` with badge `New`.
5. In the `.candidate` card containing `Jamie Taylor`: click `Prepare offer`, then `Record acceptance`, then `Confirm hire` — expect `#hire-form` visible.
6. Click `Cancel` in the dialog; expect the dialog hidden and the Jamie Taylor card still showing badge `Offer accepted` and a `Confirm hire` button (cancelling creates nothing — `docs/design-round-01.md:43`).
7. Click `Confirm hire` again; select `Operations` in `#hire-department`; click `Confirm hire & create plan`; expect the handoff step to show a card containing `Jamie Taylor` and badge `4 readiness gaps`.
8. Navigate to `Onboarding` via the nav; expect a `.card[id^="plan-"]` containing `Jamie Taylor` with badge `Needs preparation`; click `Mark complete` four times on the four critical tasks (rows whose small text contains `Required before start`); expect badge `Ready for day one` (documented decision: the non-critical intro task may remain open — `docs/design-round-01.md:21`); click one `Reopen`; expect badge `Needs preparation` again.
9. `page.reload()`; expect the Onboarding page still shows the Jamie Taylor plan (localStorage persistence); navigate to `People & access`; search or scan for a row containing `Jamie Taylor` with badge `Pre-start`.

Playwright notes for the executor: rely on auto-waiting `expect(...)` assertions after each click, since every action re-renders the DOM; scope button lookups to their card (`page.locator('.candidate', { hasText: 'Jamie Taylor' })`) because identical button labels repeat across cards.

**Verify**: `npm test -- tests/walkthrough-b.spec.js` → 1 passed.

### Step 6: Full suite green, prototype untouched

**Verify**: `npm test` → 4 passed, 0 failed. Then `git status --short prototype/` → empty output.

## Test plan

This plan *is* the test plan: 4 new tests as specified in steps 4–5. No existing tests exist to model after; the structural pattern is given in step 4.

## Done criteria

- [ ] `npm test` exits 0 with 4 passing tests
- [ ] `git status --short prototype/` → no output (prototype unmodified)
- [ ] `node --check prototype/app.js` exits 0
- [ ] Only in-scope files changed/created (`git status --short`)
- [ ] `node_modules/` is not tracked (`git status --short | grep node_modules` → empty)

## STOP conditions

Stop and report back (do not improvise) if:

- The drift check shows `prototype/` changed since `a690d31`.
- A selector or text quoted in "Current state" does not exist in the running app (the characterization is wrong — report the mismatch; do not alter the app to make a test pass).
- `python3` is unavailable or the webServer fails to start twice.
- `npx playwright install chromium` fails twice (e.g. no network).

## Maintenance notes

- Later plans (002–007) modify the app and MUST keep this suite green; plans 004–007 add their own spec files alongside these.
- The tests intentionally assert the *documented* behavior including quirks (e.g. "Ready for day one" with the intro task open). If a future design round changes a documented decision, update the walkthrough doc and the test together.
- Toast assertions race its 4.5s auto-hide; if flake appears, assert on the Activity page entry instead of the toast.
