# Personnel: core HR design and action plan

Status: discussion draft, not approved implementation scope.
Prepared: 2026-09-10. Based on the current index.html and public product documentation.

Expanded system direction: see [HR system blueprint](hr-system-blueprint.md) for the requested company/person permission editor, director workflows, recruitment-platform feasibility, Marketing collaboration, and revised navigation/delivery order. This document retains the detailed core-HR page and action definitions.

## Confirmed direction

- Build a complete internal HR system around the existing app.
- Cover approximately 40 people across four companies.
- The four companies belong to a parent holding company. Working interpretation of the user's clarification: each employee belongs to one company at a time.
- Prioritize core HR operations and deepen existing features.
- Leave requests, balances, accruals, and approvals remain in the existing separate system; integrate with it.
- Performance reviews and related talent-development modules are outside the current focus.
- This is design and planning work. Application behavior has not been changed.

## Decisions still open

Names of the holding company and four companies; company locations; whether the holding directly employs anyone; employee versus contractor coverage; HR-only versus shared access; identity/login provider; existing leave system and API; existing payroll process; document and signature providers; approval owners.

## Scale and four-company design implications

Confirmed scale: approximately 40 people total across four companies under a parent holding company. Interpret the user's clarification as one employing company per employee at a time. Proposed design: one shared HR workspace with a holding-wide view, a company filter, and company-scoped access. Confirm actual user access before implementation; a separate-company access boundary must not rely on a visual filter alone. Do not assume the holding is a fifth employer unless confirmed.

- Make employing company explicit on each employment record; keep it separate from department, location, and team.
- Provide an All permitted companies view plus individual company views. Company scope applies consistently to directory, dashboard, recruitment, documents, tasks, reports, and exports.
- Model person identity separately from employment periods. A transfer preserves the previous company's employment history; it is not just an overwritten company label.
- Keep one current employing company per person. Retain previous employment periods for transfers and rehires; concurrent employment forms are outside the current design.
- Company policies, document templates, notification contacts, and onboarding requirements can use shared defaults with company-specific overrides.
- Jobs belong to a hiring company; employee conversion carries that company forward for review.
- Store asset ownership separately from the employee's employing company when relevant; a transfer does not imply a physical equipment return.
- Any payroll preparation/export must have an explicit company and period; consolidated totals must not silently combine currencies.
- Leave integration maps the existing system's employee identity and company context where supported, without creating duplicate leave accounts on transfer.
- Keep the first interface simple at this scale: searchable tables, profiles, a shared task queue, and a few reusable templates. Defer elaborate dashboards and a general workflow designer.

Additional acceptance scenarios: an HR user authorized for all four companies can filter/export one company's staff; a company-limited user cannot access another company's records by direct link or export; a scheduled company transfer preserves historical reports; holding-wide headcount counts each person once and agrees with the sum of company headcounts for the same date and employment scope.

Working assumption: HR operates the system, while managers, IT, Finance, and employees may receive restricted access. Access by those groups is a proposal, not a confirmed requirement. Payroll depth remains open; the proposed first step is payroll preparation.

## Reference patterns worth adopting

These are documented capabilities, not findings from hands-on product trials. The proposed adaptation is our judgment.

| Reference | Documented pattern | Proposed adaptation |
|---|---|---|
| [Personio employee profile](https://support.personio.de/hc/en-us/articles/28163576044445-Overview-of-the-Employee-Profile-and-Personal-Info-tab) | Profile sections, permission-dependent edits, effective dates and employee history | One employee profile with section access and dated employment changes |
| [BambooHR onboarding](https://www.bamboohr.com/platform/onboarding/) | Candidate information carries into employee creation; configurable onboarding and offboarding tasks; document signing | Review the hire once, reuse its data, and launch the relevant onboarding plan |
| [Personio onboarding examples](https://support.personio.de/hc/en-us/articles/115002474325-Common-onboarding-templates-and-steps) | Steps assigned to HR, IT, managers, and employees; document collection | Assign tasks to responsible people instead of leaving every checkbox with HR |
| [HiBob workflows](https://www.hibob.com/platform/core/automation/) | Configurable workflows for onboarding, approvals, and document processes | Begin with specific templates for joining, changing employment, and departing; defer a general workflow builder |
| [HiBob documents](https://apidocs.hibob.com/docs/explore-docs-api) | Personal and company documents, signing/read approval capabilities and document permissions | Separate file upload, employee acknowledgement, and signature completion |
| [BambooHR access levels](https://www.bamboohr.com/blog/access-levels-bamboohr) | Own-record, manager, admin, and custom access; edits can require approval | Define permissions by action, employee scope, and field group |

## Proposed navigation

Keep the existing top-level structure initially, adding only where the job warrants it.

| Area | Pages | Purpose |
|---|---|---|
| Home | Overview; My tasks | Today's work, approaching dates, unresolved exceptions |
| Recruitment | Job openings; Applicants | Hiring records and the confirmed-hire handoff |
| HR | Employees; Onboarding; Offboarding; Documents & Policies; Equipment; IT Requests | Main operational workspace |
| Payroll | Preparation; History | Proposed HR-to-Finance handoff; scope to confirm |
| Settings | Organization; Access; Templates; Integrations | Shared configuration |

Employee profile tabs are contextual views of the same records, not separate copies. For example, a laptop assignment viewed under an employee is the same assignment shown in Equipment.

## 1. Home

Current: headcount, pipeline, vacancies, recent candidates, payroll total, social widgets.
Problem: little guidance about urgent work; no shared task ownership or deadlines.

Proposed layout: compact counts, action list, upcoming starters/departures, and a smaller company-events area. Keep kudos and birthdays secondary; optional fun content should not dominate the HR workspace.

| Action | Proposed behavior | Completion check |
|---|---|---|
| Open a count | Open the exact filtered list behind it | List and count use the same scope and dates |
| Open a task | Show employee, owner, deadline, blocker, and next action | Can act without searching another page |
| Complete / block / reassign | Update the underlying task and its history | All pages show the same result |
| Filter upcoming events | Choose period and team | Departed staff do not appear as active starters |

Candidate counts remain available to recruiting users. Financial totals are visible only with appropriate access.

## 2. HR / Employees: the foundation

Current: table, inline details, one large edit form, direct remove action.
Problem: no manager or employment history; statuses mix employment and absence; no safe guided transitions.

Directory: name, employee ID, role, department, manager, location, employment type, start date, employment status. Search and saved filters for active staff, upcoming starters, departing staff, former staff, and missing data. Compensation is not a default directory column.

Profile tabs:

| Tab | Contents | Principal actions |
|---|---|---|
| Overview | Identity, work summary, manager, key dates, outstanding work | Start onboarding; open tasks |
| Personal | Personal contacts, address, emergency contacts | Edit or propose an update |
| Employment | Job, entity, location, type, working arrangement, dates, manager | Schedule change; correct record; start departure |
| Compensation | Amount, currency, pay frequency, effective date | Propose/review change; inspect history |
| Documents | Categorized employee files and outstanding requests | Upload; request; view; download; replace version |
| Tasks | Onboarding and other operational assignments | Assign; complete; block; reopen |
| Equipment & Access | Assigned items and related IT requests | Issue; return; request access change |
| History | Who changed what, when, why, and effective date | Filter; inspect previous values |

Actions to specify:

| Action | Proposed behavior | Edge cases / completion check |
|---|---|---|
| Add employee | Minimum identity and employment fields; save draft or confirm | Detect duplicate employee ID; warn on likely duplicate person; allow personal email before work email exists |
| Import employees | Map columns, preview changes and row errors before applying | Bad rows explained; repeated imports do not silently duplicate people |
| Edit personal details | Update only permitted fields; use approval where configured | A rejected proposal leaves the current value unchanged |
| Change job/manager/location | Capture new values, effective date, reason, and approval if required | Future change does not overwrite today's record; prevent circular reporting relationships |
| Change compensation | Separate restricted action with currency and pay basis | Preserve previous amount and date; prevent ambiguous overlapping changes |
| Correct a mistake | Distinguish correction from a new employment event | Retain an audit record of correction |
| Start offboarding | Capture departure dates and launch plan | Employee remains active until the applicable employment end date |
| Archive | Remove from active directory, preserve linked history | Equipment, documents, and payroll references remain accessible to permitted users |
| Rehire | Reuse person identity with a new employment period | Preserve previous employment and restart appropriate tasks |
| Export | Export selected permitted fields and scope | Restricted fields remain restricted in exports |

Proposed employment states: Draft, Pre-start, Active, Former; show a separate departure indicator for scheduled exits. Onboarding completion is its own state. Absence is a separate read-only integration indicator, not an employment state.

Design issue to resolve: contractors may need different required fields and templates. Do not require an annual USD salary for every person.

## 3. HR / Onboarding

Current: identical checklist for all employees, policy summaries, email draft, manual sent flag.
Problem: no assignee, deadlines, blockers, or distinction between pre-start readiness and general completion.

Views: Upcoming; In progress; Blocked; Completed. Each row shows employee, start date, HR owner, critical readiness, and next deadline. Open a person to see grouped tasks for Before start, Day one, Week one, and Month one.

| Action | Proposed behavior | Completion check |
|---|---|---|
| Start onboarding | Select template, start date, manager, and HR owner; preview assignments | Works for both direct employee creation and recruited hires; avoids duplicate plans |
| Assign template | Create independent tasks with owners and deadlines relative to start date | Later template edits do not silently rewrite active plans |
| Change start date | Preview tasks whose deadlines would move | Completed tasks stay completed; rescheduling is recorded |
| Complete task | Record actor/time; require file or confirmation only when relevant | Uploading a file is distinct from HR accepting it |
| Mark blocked | Record reason, responsible person, and next follow-up | Blocker appears on HR dashboard |
| Skip task | Require a reason for required steps and suitable authority | Skipped is distinguishable from completed |
| Send welcome information | Preview first-day instructions and relevant links | Drafted, manually reported sent, and provider-confirmed sent are distinct |
| Finish onboarding | Check required tasks and unresolved blockers | Explicit completion with timestamp |
| Cancel onboarding | Record cancelled start; close or cancel pending tasks | No fake employment termination for someone who never started |

Critical rule: IT setup completed in IT Requests updates the linked onboarding task; no duplicate checkbox. Completion of one employee's task never changes another's template or task.

## 4. HR / Documents & Policies

Current: only company-policy titles and short summaries, embedded in onboarding.
Problem: no employee documents, versions, requests, or acknowledgement record.

Separate Employee documents from Company policies. Suggested employee categories: employment agreements, amendments, onboarding forms, and other company-required records. Required categories depend on actual company needs.

| Action | Proposed behavior | Completion check |
|---|---|---|
| Upload | Select person/category, visibility, and relevant dates | File appears only to permitted viewers |
| Request document | Choose recipient, document type, deadline, reviewer | Pending, Submitted, Accepted, and Needs correction are distinct |
| Replace document | Create a new version with context | Previous version remains traceable |
| Publish policy | Publish a version to a defined audience | Draft is not distributed |
| Request acknowledgement | Assign published version with deadline | Record exactly which version was acknowledged |
| Request signature | Use an explicitly selected signing integration if needed | Do not label a checkbox or uploaded file as a verified signature |
| Archive | Hide superseded material from default views | Existing acknowledgements reference their original version |
| Remind | Notify outstanding recipients | Record reminder and avoid repeated accidental sends |

A short welcome note should link to relevant policies, not duplicate their contents.

## 5. HR / Equipment (rename Materials)

Current: free-text items per employee with issued checkbox/date.
Problem: no unique item identity, return tracking, or assignment history.

Views: By employee and Inventory. Keep physical devices and software access distinguishable.

| Action | Proposed behavior | Completion check |
|---|---|---|
| Add asset | Record tag, type, model, serial if applicable, condition, location | Unique asset tag |
| Reserve / assign | Select asset and employee; record planned/actual handoff | One asset cannot have two concurrent assignees |
| Mark issued | Record date, issuer, and receipt acknowledgement if required | Linked onboarding requirement updates |
| Return | Record return date and condition | Availability and departure task update together |
| Transfer | Close previous assignment and create next | Full assignment history retained |
| Mark damaged / lost / retired | Record condition, reason, and follow-up | Unavailable item cannot be assigned accidentally |

Retain quick-add equipment requirements, but distinguish a requested laptop from an actual laptop assignment. Issued items use a status badge rather than strikethrough.

## 6. HR / IT Requests (rename IT Notifications)

Current: generated email draft and manually toggled Pending/Sent.
Problem: sent is not completed; direct hires do not receive the same request flow as converted applicants.

Views: Open; Due soon; Blocked; Completed. Fields: employee, request type, owner, due date/time, requested systems/items, status, notes.

| Action | Proposed behavior | Completion check |
|---|---|---|
| Create | Trigger from onboarding, role change, departure, or manual request | Linked employee and task; retries do not create duplicates |
| Assign | Choose responsible IT person/team | Unassigned requests remain visible |
| Start / block | Update work status with explanation | HR sees progress independently of email status |
| Complete | Confirm the requested setup/change was done | Linked task updates; sent email alone cannot complete setup |
| Cancel / reopen | Capture reason and history | Parent workflow reflects reopened work |
| Notify | Draft email initially, optional provider later | Message delivery and work completion remain separate |

Do not store account passwords in request notes. Departure requests require explicit access-removal timing rather than immediate removal when HR schedules a future departure.

## 7. HR / Offboarding (new core page)

Purpose: coordinate the end of an employment period and preserve useful records.
Views: Scheduled; In progress; Blocked; Completed.

| Action | Proposed behavior | Completion check |
|---|---|---|
| Schedule departure | Capture employment end date, last working date, restricted reason, owner, template | Dates are explicit; scheduling does not instantly deactivate employee |
| Launch tasks | Assign handover, document, equipment-return, IT, and Finance tasks | Every task has owner and deadline |
| Change dates | Preview effects on pending tasks and IT timing | No silent changes to already completed work |
| Cancel departure | Stop pending actions and notify relevant owners | Completed external actions require explicit follow-up |
| Complete plan | Resolve required tasks or record authorized exceptions | Person can be Former while an equipment return is still outstanding |

Departure does not delete records. Exit surveys and performance reviews are not required for this workflow.

## 8. Recruitment / Job Openings

Current: title, department, headcount, short description, status.
Retain and improve the existing scope; prioritize the handoff to HR.

Actions: Create draft; Edit; Open; Put on hold; Close/Fill; Archive; View linked applicants.
Add owner/hiring manager, location, employment type, target start date, and filled versus requested positions. Compensation range visibility is configurable.

Behavior: call the action Create opening until there is a real publishing integration. Closing an opening preserves candidates. Filling one of several positions does not prematurely close the entire opening. Required approval before opening is a company decision.

## 9. Recruitment / Applicants

Current: contact and position fields, stage selector, employee conversion.
Actions: Add; Edit; Attach résumé; Add note; Assign owner/next action; Move stage; Reject; Withdraw; Confirm hire; Archive.

Proposed details: candidate profile plus table; optional pipeline board after core actions are clear. Keep a dated stage history and rejection/withdrawal reasons. Interview feedback remains part of recruitment, distinct from employee performance reviews.

Confirm hire: review identity, opening, manager, department, start date, employment type, compensation as applicable, and onboarding template. Only confirmed submission creates the employee and tasks. Cancelling the form must not leave the candidate falsely marked hired. Repeating the action must not create a second employee. Rehires should link to an existing person where appropriate.

## 10. Payroll

Current: simplified monthly calculation with one tax percentage and flat deduction.
Open scope decision: internal payroll engine versus preparation/export for Finance or an existing provider.

Proposed first direction: review new starters, departures, compensation changes and missing inputs by pay period; draft, review, approve, export, inspect history. Preserve currency/pay basis; define correction and duplicate-period handling. Do not infer unpaid eligibility from an absence indicator. Leave data rules must be agreed with the existing provider/process.

No country-specific payroll formula is specified in this plan. Compensation record management belongs in core HR regardless of payroll implementation choice.

## 11. Settings and cross-page rules

Settings: departments, locations/entities, employment types, document categories, task templates, role permissions, notification destinations, integration configuration.

Proposed permission model: HR manages permitted employee records; managers access designated team information/tasks; IT accesses setup/equipment information; Finance accesses necessary compensation inputs; employees access their own permitted information/tasks. Actual roles and visibility require discussion. Technical administration should not automatically imply unrestricted access to all HR content.

All important actions specify actor, record scope, required data, validation, immediate/scheduled effect, notification, history, and recovery path. Search, export, document access, and aggregate counts must respect the same visibility rules as profiles.

Every list needs loading, empty, filtered-empty, failed-load, and failed-save states. Failed saves must preserve input and clearly offer retry. Multi-user changes must not silently overwrite one another. Notifications link to the relevant action and record delivery status honestly.

## 12. Existing leave system integration

Confirmed: do not build leave requests, approvals, balances, or accrual calculations here.

Proposed ownership: HR owns employee identity and employment details; existing leave system owns leave facts. Confirm this against the existing system before implementation.

Initial UI: read-only availability where appropriate, source link, and last successful update. Stale/failed data is shown as unavailable or outdated, not interpreted as no absence.

Integration actions: Link employee; Inspect sync status; Retry failed sync; Resolve unmatched identity; Open leave system. Use a stable external employee ID mapping rather than relying on name/email alone. Confirm supported APIs, who creates employee accounts, data direction, fields allowed to sync, deletion/deactivation behavior, and failure handling.

## Hardening findings from current code

These are implementation backlog items identified by inspection, not fixes performed in this draft.

- Persistence uses window.storage without a local implementation; reliable shared storage and migration are required.
- Role selection only hides UI; real login and enforced permissions are required for shared use.
- User-entered values are interpolated into HTML; render them safely as text/escaped attributes.
- Hire conversion marks the applicant Hired before employee form submission; cancellation needs consistent state.
- IT requests are created only for converted applicants; use one onboarding trigger for both hiring paths.
- Conversion sets ui.tab to 'it', which is not a valid top-level tab; route to HR / IT Requests.
- Employee defaults assume annual USD salary and default converted candidates to Engineering; require explicit appropriate employment data.
- Delete actions need record-specific archive/correction behavior to preserve linked history.
- Payroll excludes everyone with On Leave status and allows repeated unqualified runs; redesign eligibility and periods before real use.
- index.html and hr-system.html duplicate the app; choose one maintained entry point to avoid divergence.

## Proposed delivery sequence

1. Design employee directory/profile/actions and agree identity, employment states, roles, and leave ownership.
2. Establish persistent records, enforced permissions, validation, safe rendering, history, and import preview.
3. Complete one end-to-end onboarding example including documents, assigned tasks, equipment, and IT.
4. Complete employment-change and departure examples, including dates and exceptions.
5. Tighten recruitment-to-employee handoff and build dashboard from real tasks.
6. Connect leave and agree payroll handoff; add operational reports using the same records.

Design artifacts for each page: layout, fields, actions, status transitions, role visibility, empty/error states, and realistic acceptance scenarios. Review those before implementation of that page.

## First design session: Employees

Proposed starting screen: searchable table with Active, Upcoming, Departing, Former, and Missing information views; Add employee and Import actions; employee names open profiles.

Walk through these scenarios:

1. HR adds an upcoming hire whose work email is not yet created.
2. HR schedules a department/manager change for next month; current profile remains accurate until then.
3. A user without compensation access opens the same profile and exports the directory.
4. A departing employee still has equipment outstanding after their employment ends.
5. A former employee returns without losing their previous history.
6. A leave sync fails; HR still sees valid employment details and a clear integration warning.

Questions for discussion: mandatory employee fields; who edits versus proposes changes; who approves employment/compensation updates; employee/contractor coverage; HR-only versus wider access; directory columns preferred by HR.
