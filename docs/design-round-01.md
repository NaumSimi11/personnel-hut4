# Design round 01: company access and the hiring journey

Status: interactive design prototype, not a production implementation.

Open [the prototype](http://127.0.0.1:8000/prototype/) while the local server is running. The implementation lives in `prototype/index.html`, `prototype/styles.css`, and `prototype/app.js`. The original HR app is unchanged.

## Design decisions made concrete

- One holding overview with a company selector; four sample companies and 40 synthetic employees.
- Company profile tabs: Overview, People, Access, Hiring, Integrations.
- Searchable employee directory with employing company, title, employment status, and access preset.
- Admin opens a person, chooses a company, selects a preset, adjusts individual capabilities, and reviews an effective-access summary.
- Payroll totals, individual payroll, individual salaries, approval, and export are distinct permissions.
- Selecting an action enables required viewing permissions; removing a prerequisite removes dependent actions. This dependency is explained in the editor.
- Company grants are independent; changing a person's Company B grant does not overwrite their Company A grant.
- Permission changes appear in activity history with added and removed capabilities.
- A five-step hiring workspace connects request approval, job channels, Marketing, applications, and onboarding.
- External LinkedIn recruitment, promotional posting, and manual channel publication are presented as separate capabilities.
- Careers-page publishing and applications can be simulated locally. External publication is never implied.
- Cancelling hire confirmation keeps the accepted offer without creating an employee. Confirming creates one employee and one onboarding plan.
- Critical pre-start requirements drive readiness; finishing all critical items can show Ready for day one while a first-day introduction remains outstanding.

## Walkthrough A: configure the Director

1. From Overview, click Configure a director.
2. Company A / Alex Morgan opens with an example Director preset.
3. Enable View company payroll totals. Notice that individual salaries and payroll export remain disabled.
4. Review the summary, then Save permissions.
5. Reopen the editor and select Company B. It starts with no access for this person; Company A's grant remains intact.
6. Save a separate Company B grant if desired, then inspect Activity.

All grants are demo configuration. The app remains in Admin view. These controls do not secure browser data or enforce real user access.

## Walkthrough B: request to employee

1. Open Hiring workspace and select Company A / Operations Coordinator.
2. Review the request and approve it. Job publication is still separate.
3. Open Job & channels, preview the careers page, and publish the demo listing.
4. Preview the application form and submit a made-up applicant name. It appears under the correct job/company.
5. Open Promotion, request the Marketing brief, review the draft, submit for review, and approve.
6. Optionally record an HTTPS example URL as a manual posting record. This sends nothing externally.
7. Under Applications, advance Jamie Taylor from Interview to Offer, then record acceptance.
8. Open Confirm hire and cancel once; no employee is created.
9. Confirm again, choose a department, and submit. Open the resulting onboarding plan.
10. Complete the required tasks and observe readiness change. Reopen one to restore the readiness gap.

## Limits and decisions for the next round

- Names and company labels are placeholders. Company names, branding, and actual user assignments are still needed.
- One sample hiring request per company is provided; a general create-request flow is not part of this slice.
- The prototype runs all workflow roles through one Admin session. Live authentication, server-enforced permissions, scoped approvals, delegation, and concurrency controls must be designed and built.
- Tasks use simple manual completion to test the screen flow. Live evidence review, deadlines, reminders, reassignment, and blockers remain in the full plan.
- Offer drafting, compensation review, résumé uploads, scheduling, signing, and public careers hosting remain future implementation work.
- Local browser storage is for fictional demo data only. Shared persistence, audit protection, backups, and migration are not implemented here.
- Existing leave integration and payroll preparation remain in the overall blueprint, outside this design slice.

## Review questions

1. Does the company profile expose the information a director needs first?
2. Are permission categories understandable, especially payroll summary versus individual salary visibility?
3. Which actions should company directors be allowed to approve, and which stay with holding HR/Admin?
4. Should Marketing content review belong to HR, the Director, or a Marketing approver?
5. Which onboarding requirements must actually be complete before the person starts?
