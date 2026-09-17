# Testing Personnel end to end

A scripted run through the whole app, shaped like real work: you are setting up a
company of ten people, and two new colleagues start in a fortnight.

Follow it top to bottom. Each step says **where to click** and **what should
happen**. When something does not happen, write down the step number — that is
the bug report.

Allow about two hours for the first pass.

---

## Before you start

**You are testing against the live system.** There is no separate practice
environment. Everything you create is real: real rows, real notifications, and
possibly real email. So:

- **Prefix every name you invent with `TEST`** — `TEST Marko Petrov`, `TEST
  Frontend Engineer`. It makes the cleanup at the end possible.
- **Do not touch records that are not yours.** If a name is not prefixed `TEST`,
  leave it alone.
- Use `@example.test` addresses for anyone you invent, never a real inbox.

**One account is enough.** Approving an offer used to refuse the person who
drafted it; since September 2026 the author may approve their own offer, so you
can run this whole guide alone. Who approved is still recorded on the offer.

**What to have open:** the app, and a notepad for step numbers that misbehave.

---

## Part 0 · Set the company up

Everything later depends on this. Skip it and the new joiners get an empty
checklist and no equipment.

### 0.1 Pick a company

**Companies** → open one you are willing to put test data in.

You should see tabs across the top: Overview, People, Structure, Access, Hiring,
Documents, Equipment, Payroll, Leave, Projects, Integrations, Activity, Settings.

### 0.2 Departments and locations

**Structure** tab. Add a department (`TEST Engineering`) and a location (`TEST
Skopje Office`).

✅ Both appear in the lists immediately.

### 0.3 The onboarding checklist

**Settings** tab → the checklists section.

The first time you edit, the company copies the holding's default — eleven
onboarding lines and eight offboarding ones. Read them. Add one of your own:
`TEST Give building access card`, owner **IT**, due **before start**.

✅ Your line appears in the list, and the holding default is untouched for other
companies.

### 0.4 The starter kit

**Settings** tab → starter kit.

This is the list of things every new person gets. Confirm it holds the usual —
laptop, monitor, keyboard & mouse, badge, phone, desk & chair, software licences.

✅ Whatever is listed here will turn into an IT request for every new hire.

### 0.5 Who gets told about a new hire

**Settings** tab → handover recipients.

Add at least two:
- **IT** — when *new hire* — fields: work email, department, start date
- **Accountant** (an outside address, `accounting@example.test`) — when *new
  hire* — fields: national ID number, bank account, salary

The second one needs the sensitive fields, and you can only place those if you
hold `personal.view` / `salary.view`. If the fields are greyed out, that is
correct behaviour, not a bug.

✅ Both recipients are saved, each showing which fields they will receive.

### 0.6 Policies

**Documents** tab → policies.

There should be six holding-wide drafts. Publish at least two, so the new joiners
have something to acknowledge.

✅ Published policies show a version number.

### 0.7 Payroll estimate

**Settings** tab → payroll estimate. Set a tax rate and a flat deduction.

✅ Saved. This is what turns a gross figure into a net one later.

---

## Part 1 · The eight people already working there

Real companies do not start empty. Put eight existing colleagues in before you
hire anyone.

### 1.1 Add the first one by hand

**People & access** → `Add employee`.

Fill all four sections:
- **Identity** — `TEST Ana Stojanova`, work email `test.ana@example.test`
- **Employment** — job title, company, department (`TEST Engineering`), start
  date **in the past**, manager
- **Personal & emergency** — including national ID and bank account
- **Pay** — a salary proposal

Press `Create employee`.

✅ The person appears in the directory.
✅ Opening them shows the private card, because you hold `personal.view`.
✅ **No onboarding checklist was started** — their start date is in the past.

### 1.2 Add seven more, faster

Repeat 1.1 seven times, or use the import if you prefer — **People & access** →
import, with the same columns.

Vary them: different departments, one with no manager, one part-time.

✅ Eight people, all prefixed `TEST`.

### 1.3 Check what the directory tells you

Search `TEST`. Look at the rows.

✅ Each row distinguishes itself — you can tell two people apart without opening
them.
⚠️ If two of your test people look identical, note the step number. That is worth
knowing about.

---

## Part 2 · Equipment they already hold

### 2.1 Register some kit

**Equipment** → `Add asset`. Create four:

| Tag | Type | Model | Company |
|---|---|---|---|
| `TEST-L01` | Laptop | Dell Vostro 3520 | your company |
| `TEST-L02` | Laptop | MacBook Air | your company |
| `TEST-M01` | Monitor | Dell S2721HS | your company |
| `TEST-P01` | Phone | Samsung A55 | **the holding pool** |

✅ Each row reads: tag, then `type · company · model · holder`, then status.
✅ The one with no company shows **Holding pool**.
✅ All four say **magacin** as the holder — nobody has them yet.

### 2.2 Give one out

On `TEST-L01` → `Reserve` → choose `TEST Ana Stojanova` → `Confirm reservation`
→ `Issue`.

✅ The row's holder changes from `magacin` to her name.
✅ A **handover form PDF** is generated and filed under her documents.
✅ Open her record → Documents → the PDF is there and opens.

### 2.3 The asset's own page

Click the tag `TEST-L01` in the register.

✅ You land on a page for that one asset: its numbers, type, model, serial,
which company owns it, and who holds it.
✅ **History** reads newest first and ends with `Registered`.
✅ `Add a note` → `Service or repair`, "Battery replaced under warranty" → the
line appears in the history against Ana's name, because she held it at the time.

### 2.4 Take it back, then hand it out

Equipment never goes from one employee straight to another. It comes back to
magacin first, and goes out again. Two acts, two forms. The app will not let you
skip the middle.

Still on `TEST-L01` (Ana holds it), press `Ask for it back`.

✅ There is no person picker — you are not choosing where it goes, only asking
for it back.
✅ Condition `As issued`, reason `Needed for a new starter` → `Review and sign`.
✅ The dialog says what you are signing: *"I confirm that I am asking for the
equipment listed on this form back on behalf of …"*. Type your name → `Sign`.

Nothing has moved yet:

✅ The page says it is waiting on a signature and names Ana.
✅ `Held by` still reads **Ana**.
✅ Ana is notified, and gets an email if she has a work address on file.

Sign in as **Ana** → `/me` → Equipment.

✅ The row reads `TEST-L01 — <your name> is asking for this back`, with
`Confirm I handed it over` and `I still have it` — not "accept", because she is
not accepting anything, she is confirming she gave it up.
✅ `Confirm I handed it over` → the statement is *"I confirm that I have handed
back the equipment listed on this form…"* → sign.
✅ A **return form** is filed under Ana's documents, listing what she handed over.

Back on the asset page:

✅ `Held by` now reads **magacin**, and the button has changed to
`Hand it to someone`.

Now hand it out:

✅ `Hand it to someone` → the list has people **currently employed by the company
that owns it**. Pick `TEST Marko Petrov` → `Review and sign` → the statement is
now *"I confirm that I am handing over the equipment…"* → sign.
✅ Sign in as Marko → `/me` → `Accept it` → *"I confirm that I have received the
equipment… and that I will return it on request or when I leave."*
✅ `Held by` is now **Marko**, and a **handover form** is filed under his documents.

Try to skip the middle:

✅ While Marko holds it, there is no `Hand it to someone` button at all — only
`Ask for it back`.

### 2.5 When the person has no login

Some people in the app have no account. Find an asset held by one of them (or
try it with any employee who has never signed in).

✅ `Ask for it back` → before you sign, the form warns you: they have no account,
so somebody else in IT or HR signs it in on the company's behalf.
✅ Sign it, then sign in as a **different** HR person → they can receive it.
✅ The form says *"I confirm that I have received the equipment on behalf of
<company>"* — it does **not** pretend the holder signed.

### 2.6 What changed hands

From `/equipment`, press `What changed hands`.

✅ Three tabs: `Waiting on a signature`, `No signed paper copy`, `Everything`.
✅ Your round trip above shows as **two** rows — `Ana → magacin` and
`magacin → Marko` — newest first.
✅ Anything you signed in the app but never printed, signed by hand and uploaded
back shows under `No signed paper copy`, in amber.

### 2.7 Find the ones the books never matched

On `/equipment`, open the holder filter.

✅ `Kept somewhere, not with a person` — things the Excel put in an office, a
car, a server, or against the company itself. These are recorded correctly.
✅ `Books name a person we have not matched` — a much shorter list. These are
real people holding real kit that the app does not know about. Hand each one out
properly and the note disappears.
✅ `In magacin` no longer includes either — it means genuinely nobody has it.

### 2.8 Prove the pool rule

Try to reserve `TEST-P01` (holding pool) for someone at a **different** company.

✅ It is allowed — pool assets go to anyone employed anywhere.
✅ Now try the same with `TEST-L01`, which belongs to one company. It should only
offer that company's people.

---

## Part 3 · Hiring the two new joiners

This is the long one. Do it once fully; the second joiner can be added the short
way in Part 4.

### 3.1 Raise the request

**Hiring** → `Request a hire` → fill it in:
- Job title: `TEST Frontend Engineer`
- Headcount 1, start date **two weeks from today**, manager: one of your eight

→ `Request hire`

✅ It appears under Hiring requests, awaiting a decision.
⚠️ Try typing nonsense in the job title first — `dvsdv`. It should be **refused**
with *"That does not look like a job title."* If it is accepted, note it.

### 3.2 Approve it

On the request row → `Approve`.

✅ Status goes to approved. (You can approve your own hiring request — only
*offers* require a second person.)

### 3.3 Turn it into a job

On the approved row → `Prepare job`.

✅ The job page opens, showing a strip across the top:
`01 Hiring request → 02 Job ready → 03 Published → 04 Applications → 05 Hired →
06 Onboarding → 07 First day`
✅ A **Next action** card tells you what to do: write the description.

### 3.4 Write it and open the role

**Description** tab → write a few lines → save. Back on **Overview** → `Mark
ready`, then `Open job`.

✅ The strip moves to `02 Job ready`.
✅ Optionally publish it on the **Channels** tab and watch the strip reach `03`.

### 3.5 Add a candidate

**Applications** tab → `Add candidate` → `TEST Marko Petrov`,
`test.marko@example.test` → `Save candidate`.

Then move them along, one button at a time:
`Move to screening` → `Move to interview`

✅ The strip reaches `04 Applications`.
✅ The **Candidate next actions** card lists them with what to do next.

*Optional, worth doing once:* **Interviews & Offer** tab → `Schedule interview` →
`Save interview` → `Write scorecard` → `Submit scorecard`.
✅ Scorecards stay hidden from other interviewers until submitted.

### 3.6 The offer

**Interviews & Offer** tab → `Prepare offer` → `Draft offer` → fill salary,
currency, start date, employment type → `Save terms` → `Submit for approval`.

✅ An **offer strip** shows where you are:
`01 Drafted → 02 In approval → 03 Approved → 04 Extended → 05 Accepted`

Press `Approve` yourself — you drafted it, and that is now allowed.

Then `Mark as extended` → `Candidate accepted`.

✅ The strip reaches `05 Accepted`.

### 3.7 Hire them

`Confirm hire` → the employee dialog opens, pre-filled from the candidate and the
offer. Complete the personal and bank details → `Complete hire`.

✅ A success panel offers **Open checklist** and **Open record**.
✅ The job strip reaches `05 Hired`.
✅ **An onboarding checklist started automatically.**

---

## Part 4 · The second joiner, the short way

Not every hire comes through recruitment.

**People & access** → `Add employee` → `TEST Ivana Nikolova`, start date **two
weeks from today**.

✅ Because the start date is in the future, an onboarding checklist **is**
started this time.

---

## Part 5 · Getting both of them ready for day one

**Onboarding** in the left nav.

✅ A summary line reads something like
`2 in progress · N readiness gaps · 2 starting this week`.
✅ Both joiners are listed, each row naming their **role**, not just their name.

Open the first one.

### 5.1 Read the plan page

✅ The journey strip runs `01 … 07`, sitting on `06 Onboarding`.
✅ A **Next** line names the single most urgent thing, e.g.
*"Employment agreement signed — HR, 3 days overdue"*.
✅ A section bar: **Checklist · Welcome note · Starter kit · Handover**. Click
each — the page jumps, and the heading is not hidden behind the bar.
✅ The readiness badge is clickable and takes you to the first gap.

### 5.2 Work the checklist

Tick lines as you go. Try each of:
- tick one ✅ progress moves
- **Skip** one, with a reason ✅ it shows as skipped with the reason
- **Block** one, with a reason ✅ it shows red, and becomes the **Next** line
- `+ Add task` — a one-off for this person only

✅ Ticking *"Personal, ID and bank details collected"* is **not** needed — it
ticks itself once the record has those fields.

### 5.3 Starter kit and IT

Scroll to **Starter kit**.

✅ It lists the items from step 0.4 as an IT request.
✅ Tick items as issued; naming a registered asset (`TEST-L02`) issues it to the
person in one go.
✅ When every item is issued, the *"Starter kit issued"* checklist line ticks
itself.

### 5.4 Welcome note

**Welcome note** section → `Preview`.

✅ It is built from the record: role, start date, manager, first-day details, and
the policies to read.
✅ `Send` queues it to their personal email and files it as a PDF.
✅ The *"Welcome note sent"* line ticks itself.

⚠️ **Sending may deliver real email.** Check the address is `@example.test`
before pressing it.

### 5.5 The handover

**Handover** section. This is the most informative screen in the app.

✅ Each recipient from step 0.5 shows **green** (sent) or **red** (not sent).
✅ A red one **names exactly what is missing** — e.g. *"Not sent — missing
Address for Accountant, National ID number, Bank account"*.
✅ Go and fill one of those on the person's record, come back, press `Resend`.
The row turns green.
✅ `Mark as sent` records one you did by hand.
✅ The *"Handover sent"* checklist line ticks itself.

### 5.6 Finish

When every required line is done → `Finish onboarding`.

✅ Refused while anything required is still open.
✅ Once finished, the journey strip reaches `07 First day`.

---

## Part 6 · Ordinary life

### 6.1 Leave

**Leave** → book time off for one of your eight. Approve it as the manager.

✅ It appears on the dashboard's *away today* when the date arrives.

### 6.2 Kudos

**Kudos** → record one for a colleague, tagged with one of the holding's values.

✅ It appears on the wall with its value pill.

### 6.3 Documents

Open a person → Documents → upload something.

✅ It is listed, private, and downloadable through a signed link.

### 6.4 The dashboard

**Overview**.

✅ Counts reflect what you have created.
✅ *Needs a decision* lists only things genuinely waiting on you.
✅ Every tile respects your capabilities — a plain employee sees far less.

### 6.5 Notifications

**Notifications** in the left nav.

✅ Items from your testing are listed.
✅ **Clicking one takes you somewhere that exists.** If any leads to *"This
person no longer exists"*, note the step — that is the class of bug we fixed
today and it should not recur.

---

## Part 7 · Someone leaves

Pick one of your eight.

Open their record → `Schedule departure` → set a last working day → confirm.

✅ An offboarding checklist starts.
✅ **Offboarding** lists them.
✅ Any equipment they hold is listed, and a **return form PDF** is generated.
✅ Upload a signed scan as version 2 → the *"return form signed"* line ticks.
✅ `Cancel departure` puts everything back — try it, then schedule it again.

---

## Part 8 · Reports

**Reports**.

✅ Headcount matches what you created.
✅ Payroll shows gross, tax, deductions and **net**, using the rates from step
0.7, marked as the accountant's estimate.
✅ CSV export carries the same numbers.

---

## Cleanup

When you are done, list everything you created — every `TEST ` name, every
`TEST-` asset tag — and ask for it to be removed. Deleting people has
dependencies (documents, handover sends, employment periods) that must go in
order, so do not delete by hand from the database.

---

## Things that will look odd, and are not your fault

- **Hut 4 and Liquiditas look behind** on equipment counts. They are: Hut 4 was
  last counted in 2024, Liquiditas never.
- **The equipment register may be empty** until the spreadsheet import is run.
  Until then Part 2 is the only equipment in the system.
- **`office` is not a person.** In the imported data, 42 items are held by
  "office" — a location. The import deliberately refuses to guess a person from
  it.
- **You can now approve your own offer.** This was deliberately forbidden until
  September 2026; the rule was dropped because one person often holds
  `offer.approve` alone. `offers.approved_by` still records who approved.
- **Payroll still keeps the two roles apart.** The person who prepares a payroll
  period cannot approve it. That control was left in place — only offers
  changed.
- **The попис — the annual count — does not exist yet.** It is the next slice of
  work. Nothing in this guide tests it.

---

## The short checklist

| # | Thing | Works? |
|---|---|---|
| 0 | Company set up: structure, checklist, kit, handover, policies, payroll | ☐ |
| 1 | Eight existing people added and tellable apart | ☐ |
| 2 | Equipment registered, issued, handover PDF filed | ☐ |
| 3 | Full hire: request → job → candidate → offer → hired | ☐ |
| 4 | Second joiner added directly, checklist started | ☐ |
| 5 | Both prepared: checklist, kit, welcome note, handover green | ☐ |
| 6 | Leave, kudos, documents, dashboard, notifications | ☐ |
| 7 | Departure scheduled, return form, cancel departure | ☐ |
| 8 | Reports and payroll net figures | ☐ |

Anything unticked, tell us the step number.
