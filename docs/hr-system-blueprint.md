# Personnel: holding-wide HR system blueprint

Discussion draft — 2026-09-10. Extends [the core HR plan](hr-product-plan.md). No integrations are connected and no application changes are implemented by this document.

## Product objective and agreed context

Approximately 40 people, four companies owned by a holding, one employing company per person. Deliver a shared HR workspace that connects directors, HR, IT, Finance, and recruitment marketing through scoped access and explicit handoffs. Leave remains in the existing separate system. Employee performance reviews remain outside this phase.

New explicit requirements: an admin opens a person and configures what that person can do for a company; company recruitment channels should support publishing jobs and receiving applications where available; Marketing can collaborate on promotional posts.

Proposed defining feature: a connected hiring workspace that carries a company hiring request through approval, job distribution, candidate management, confirmed hire, documents, and first-day readiness. HR sees the next owner and unresolved blocker at every handoff. Platform feasibility is separate from the internal workflow.

## 1. Proposed top-level pages

| Page | Tabs / contents | Main actions |
|---|---|---|
| Home | My tasks, Approvals, Upcoming, Company overview | Act, reassign, resolve blocker, open filtered records |
| Companies | Overview, People, Hiring, Documents, Access, Integrations; Payroll if permitted | Edit company, manage access, inspect hiring/readiness, configure connections |
| People | Directory, employee profiles, employment history | Add/import, edit, schedule change, transfer, rehire |
| Recruitment | Hiring requests, Jobs, Applications, Interviews & Offers, Promotion | Request, approve, publish, evaluate, schedule, confirm hire |
| HR Operations | Onboarding, Documents & Policies, Offboarding | Assign, request, review, acknowledge, complete |
| Equipment & IT | Assets, Assignments, Requests | Reserve, issue, return, set up access, confirm completion |
| Payroll | Preparation, Period history | Review changes, approve, export; processing depth still open |
| Reports | Headcount, Hiring, Readiness, Documents, Equipment | Filter, inspect, export permitted fields |
| Administration | Access, Templates, Organization settings, Integrations, Audit history | Configure, preview, save, revoke, troubleshoot |

This revises the earlier minimal-navigation proposal to give Companies and Recruitment explicit workspaces. Final navigation density is a design decision: at 40 staff, avoid showing users pages they do not need.

## 2. Company profile

Overview shows company identity, HR contact, director, headcount, open hiring requests, upcoming starters/departures, and outstanding tasks. Shared holding defaults can be overridden for branding, document templates, policies, notification contacts, and workflow owners.

Company identity, employing company, job title, reporting manager, and system access are distinct. Being employed by Company A does not prevent an explicitly authorized holding HR user from accessing Company B. A Director job title alone never grants payroll access.

Access is editable through both Companies > Company > Access > Person and People > Person > Access. Both operate on the same grants. The person must have an associated user account to sign in; an employee record alone is not an account.

## 3. Exact admin permission flow

1. Admin opens a company, selects Access, and selects or invites the person.
2. Admin sees the person's employment/title as context and selects a permission preset, for example Company Director.
3. Admin selects the company scope and, where appropriate, team or assigned-job scope.
4. Admin adjusts individual capabilities with checkboxes. Sensitive capabilities are separate: payroll summaries, individual compensation, exports, approvals, and access administration.
5. Preview shows effective access in plain language and highlights additions/removals before Save.
6. Save records who changed access, when, and the before/after grant. The new permissions apply to subsequent requests, including existing sessions.

Example preview: “Alex can view Company A employees, review applicants for assigned jobs, and approve Company A hiring requests. Alex cannot view individual salaries, export payroll, access Company B, or grant permissions.”

Presets are starting configurations. Suggested presets: Holding HR, Company HR, Company Director, Hiring Manager, Recruiter, IT, Finance, Marketing, Employee. Admin is a separate explicit administrative grant. Job titles and preset names can match without becoming automatically linked.

| Capability | Independent controls |
|---|---|
| Employee directory | View; own/team/company scope |
| Personal information | View restricted fields; edit; review proposed changes |
| Employment | View; edit; schedule transfer; start departure |
| Compensation | View individual amounts; propose changes; approve changes |
| Payroll | View summaries; view individual lines; prepare; approve; export |
| Recruitment | View assigned jobs/company jobs; request opening; approve opening; edit; publish |
| Candidates | View permitted applications; interview feedback; change stage; approve offer |
| Documents | View by category; upload; request; review; publish policies |
| Equipment and IT | View requests; assign; update; confirm completion |
| Marketing | View approved public job brief; draft creative; approve content; publish; schedule |
| Reports | View permitted reports; export separately |
| Integrations | Inspect status; connect/reconnect; disconnect |
| Access | View access; grant/revoke within explicit delegated scope |

Do not display every combination as a giant grid. Use grouped permission sections with expandable sensitive actions. Incompatible combinations explain their dependency, such as approval requiring access to the relevant record.

Permission semantics: default deny; company/team/job scope applies to each action; explicit denial overrides a preset grant; no scope automatically expands to sibling companies. Start with one preset per company plus explicit overrides to keep access understandable. Holding-wide access is deliberately granted. Exports, searches, counts, files, and direct URLs enforce the same permissions. Granting payroll view never implicitly grants exports or approval.

Only users with explicit access-management rights may edit grants, and they cannot grant outside their delegated authority. Prevent removing the last recovery-capable admin. Log revocation; do not use the demo role selector as real authorization. Preview mode is a clearly labeled simulation, not silent impersonation.

Approvals route to a named owner or explicitly configured role within the correct company. If no eligible approver exists, show Unassigned rather than skipping approval. Rules for requester self-approval, substitutions, and spending thresholds remain to be agreed. Proposed default: requesters do not approve their own requests.

## 4. Connected hiring workspace

Each approved role has one workspace with: Overview, Job description, Channels, Applications, Interviews & Offer, Promotion, Activity.

| Step | Owner | User action | Result |
|---|---|---|---|
| Hiring request | Director/manager | Request hire with reason, headcount, budget range, target date, manager | Company-scoped draft submitted for approval |
| Approval | Configured approver | Approve, request changes, reject | Decision history; approved brief available to HR |
| Job preparation | HR/recruiter | Complete role description, screening questions, application destination | Validated job ready for channel selection |
| Distribution | Authorized publisher | Preview each channel; publish selected destinations | Separate status/link/errors for every destination |
| Promotion | Marketing | Draft post and creative; submit for review; publish or hand off | Promotional record linked to job and company page |
| Intake | Careers form or approved integration | Receive application | Correct job/company, original source, receipt time, documents |
| Review | Recruiter/assigned manager | Record evidence, next action, interview feedback | Visible owner, deadline, and stage history |
| Offer | HR and configured approver | Prepare/review offer; record acceptance | Confirmed accepted details ready for employment creation |
| Hire | HR | Confirm person, company, manager, dates, terms, onboarding plan | Employee created once, candidate linked, tasks assigned |
| Readiness | HR/IT/manager/new hire | Complete documents, equipment, accounts and first-day tasks | HR sees actual readiness before start |

Approval rules and notification triggers are product proposals. No external publishing or messaging is authorized or performed during this planning phase.

Hiring request status: Draft, Submitted, Changes requested, Approved, Rejected, Cancelled.
Internal job status: Draft, Ready, Open, On hold, Filled, Closed.
Per-channel status: Not selected, Ready, Queued, Submitted, Live, Action required, Failed, Closing, Closed. Provider confirmation determines Live/Closed; clicking publish does not.
Marketing status: Requested, Draft, In review, Changes requested, Approved, Scheduled, Published, Failed, Cancelled.
Application status: New, Screening, Interview, Offer, Hired, Rejected, Withdrawn. Any additional stages must have an operational purpose.

Keep these states independent. A job can be live on the careers site while one external board rejects it. A promotional post is not a job listing. Closing a job does not imply all its promotional posts were deleted.

## 5. Recruitment integrations: verified feasibility

Documentation reviewed 2026-09-10. Availability still depends on our account eligibility and provider approval; no claim is made that our custom internal system qualifies.

| Capability | Finding | Plan |
|---|---|---|
| LinkedIn job publishing and application delivery | Apply Connect supports job management and application webhooks; access restricted to approved developers/partners | Investigate eligibility or a supported ATS partner; do not promise access from simply connecting a company page |
| LinkedIn company-page promotion | Community Management and Posts APIs support company content with program access and appropriate page authority | Treat as a separate integration from recruitment; app permission and provider page permission are both required |
| Indeed job distribution and applications | Job Sync integration documents agreement/request/review and application delivery | Evaluate partner path; maintain channel-specific requirements |
| Company careers pages | Owned application form and job pages are directly buildable | First dependable intake source, with company branding and source-tagged links |
| Other/local recruitment boards | Capabilities have not yet been researched because boards are unspecified | Inventory actual channels, then check APIs, supported ATS connections, exports, or manual handoff |

Sources:
- [LinkedIn Apply Connect jobs](https://learn.microsoft.com/en-us/linkedin/talent/apply-connect/create-apply-connect-jobs)
- [LinkedIn Community Management](https://learn.microsoft.com/en-us/linkedin/marketing/community-management/community-management-overview)
- [LinkedIn Posts API](https://learn.microsoft.com/en-au/linkedin/marketing/community-management/shares/posts-api)
- [Indeed Job Sync integration](https://docs.indeed.com/job-sync-api/integrate-with-job-sync-api)

Fallback: prepare approved job text and tracked careers link, assign manual publication, record the external URL and who verified publication. Import supported exports with a preview, or manually add applications with a source label. Do not represent manual records as automatically synced. Do not assume access to LinkedIn messages or historical applicants.

Connection settings per company: provider, external organization identifier, linked authorizing account, supported actions, authorization state, last successful sync, errors, and reconnect action. A holding connection must explicitly identify which external company pages it controls. Show only capabilities available to that connection.

Reliable intake: verify provider delivery, save original source identifiers, handle retries without duplicate applications, and retain separate applications when a person applies for different jobs. Candidate identity matching must not silently merge applications or expose another company's recruitment history. Respect provider-specific duplicate handling requirements. Surface unmatched jobs for resolution; do not guess company routing.

Reliable publishing: store each channel's external job ID, publication URL, latest submitted revision, and confirmation state. Retry the failed channel only. Changing an approved job description may require reapproval before updating public content. Show expired/disconnected connections and closure failures prominently.

## 6. Marketing collaboration

HR selects Request promotion from an approved job. Marketing receives company/brand, public job brief, audience, destination link, requested channels, deadline, and requester. Marketing drafts copy and attaches creative, then routes it to the configured reviewer. Approved content can be published through an authorized connection or assigned for manual posting.

Marketing receives approved public information, not résumés, interview feedback, private compensation, or unrelated employee records. Permission to draft is separate from permission to publish. Published salary ranges, if any, must come from the approved public job brief.

First version: job-linked content request, draft, review, publishing record, source-tagged careers link. Later: provider-supported scheduling and analytics. Paid campaigns, budgets, and ad purchasing are separate scope; no automatic ad spend.

## 7. What makes this useful to HR

1. Every hiring/onboarding item has an owner and next action; HR sees overdue or blocked handoffs in one queue.
2. Candidate-to-employee conversion avoids retyping and creates the correct company's onboarding tasks.
3. Directors get a focused company workspace with exactly the permissions the admin grants.
4. HR sees each job's publishing status, applications, promotion requests, and staffing outcome together.
5. Readiness describes concrete missing items, such as an unsigned document or unavailable laptop, rather than a misleading average percentage.
6. Source reports connect applications to interviews and hires where tracking data supports attribution; unknown sources remain unknown.

Optional assisted features after the core workflow works: draft descriptions from an approved brief; draft promotional copy; summarize candidate-provided material with references to the original; summarize outstanding HR work. Humans review external messages and hiring decisions. No automatic candidate rejection or unexplained suitability scores are proposed.

Define baseline measures before promising improvements: time spent re-entering hire data, time applications wait for a next action, overdue operational tasks, readiness at start date, publication failures, and duplicate records. These measure the HR workflow, not employee performance reviews.

## 8. End-to-end acceptance scenarios

- Admin gives a Director Company A payroll-summary view but no individual salary/export access; all screens, direct links, and exports agree.
- Admin grants HR Company A and B access; C and D remain inaccessible. Employment in A does not automatically restrict or expand these explicit grants.
- Removing publishing permission prevents a later publish attempt. Scheduled jobs recheck the applicable authorization before execution under the chosen scheduling policy.
- Marketing can draft a public Company B post without opening its candidate files.
- Publishing succeeds on careers site and fails on an external board; the job shows partial distribution and retries only the failure.
- Provider retries the same application; one application appears. A different application from the same person remains a distinct record.
- A connector delivers an application for an unknown job; HR/admin sees a routing exception without assigning it to the wrong company.
- Hiring confirmation is retried after a timeout; exactly one employee and onboarding plan are created.
- Changing a new hire's start date previews deadline changes and leaves completed work intact.
- A company transfer updates future assignment/history without granting the transferred person new administrative access.
- Leave data is stale; employment records remain usable and the absence indicator shows its freshness accurately.

## 9. Proposed build/design sequence

1. Specify Companies, user accounts, permission presets/overrides, access preview, and audit behavior. Sketch the admin-to-director access flow.
2. Build the employee record foundation and shared task/document relationships described in the core plan.
3. Design one complete hiring request through company careers application, confirmed hire, and onboarding readiness. Validate with one company, then all four.
4. Add recruitment marketing briefs and reviews plus manual external publication records.
5. In parallel with product design, assess provider eligibility and existing ATS options; implement the first approved integration only after capabilities are verified for our accounts.
6. Complete employment changes, offboarding, leave connection, payroll handoff and operational reports.

Stages are proposed sequencing, not a reduction in the full core-HR scope. Integration discovery starts early so restricted access does not surprise the project late.

## 10. Decisions needed next

- Which recruitment platforms each company uses today, including local boards and any existing ATS.
- Whether each company has a separate LinkedIn page and who administers those pages.
- Who approves a hiring request, an offer, and a public post; whether this varies by company.
- Which roles need access first: holding HR, directors, recruiting managers, IT, Finance, Marketing, employees.
- Whether directors can see payroll totals, individual pay, approve changes, or export; define these independently.
- Name/capabilities of the existing leave system and the payroll process.

Next design artifact: company profile and person access editor, followed by one real hiring scenario. Existing core-HR action definitions remain in the linked plan.
