# 061 — Who has access to what (migrations 0075 + 0076)

task.md: *"onobading, we need to add access to the actual worek. - the manager
mange that access, and on the offboarding we need to have preview what we need
to shut down."*

## What was there

Two checklist lines, since 0040, with nothing behind either: `system_access`
("System access granted") on the way in, `access_removed` ("Accounts and
access removed") on the way out. Both a single tick. Nobody could answer *what
does this person actually have* — which is the question the last day asks, and
the reason somebody leaves and their mailbox does not.

## What this is, and is not

The memory, and nothing else. A holding-wide list of systems, and a row per
person saying they were given one and when it was taken away. No provisioning,
no integration, and no credentials: `account` holds a username or a mailbox,
never a password — nothing here opens anything on its own.

- **Seeing it:** the person themselves, IT and HR where they work, the manager
  named on their employment, admins. Knowing what you have is not privileged;
  the list nobody could produce is what caused the problem.
- **Keeping it:** IT (`it.assign`), the manager, admins — and deliberately
  *not* the person themselves, who could otherwise record that they had been
  given the finance system.
- **Revoking keeps the row.** The last day's question is "what did they have",
  and an answer that deletes itself is no answer.
- **The two lines answer themselves**, with one condition that keeps the
  offboarding one honest: a person who never had anything recorded has not had
  it "removed", so that line stays open for a person to answer.

## The card

One component on both checklists, reading differently because the question
does. On the way in, a list you add to. On the way out, "Access to shut down"
— what is still open, each with a button, and an empty state that says *if
that looks wrong, it means nobody wrote it down* rather than implying all
clear.

## What review caught (0076)

Five corrections, before anybody used it:

1. **Both ticks matched across every company** while ticking one company's
   plan. An old revoked row elsewhere ticked "Accounts and access removed" —
   the exact lie 0075's own comment set out to prevent — and a live account
   elsewhere ticked "System access granted" on a new employer's checklist.
   Now scoped to the plan's company. The smoke block builds the real scenario:
   a transferred person whose access sits in a company they no longer work in,
   which is the only way to have both, since `no_overlapping_employment`
   forbids two employments at once.
2. **`revoke_access` overwrote the grant-time note** — the "where to go to
   remove it" sentence — at the moment somebody needed it most. It has its own
   column now.
3. **The card guessed who may manage** from capabilities alone, so the
   capability-less manager the feature was built for got no buttons.
   `my_access_rights` answers with the same helpers the writes use.
4. `access_systems` had an `admin_write` policy and only a SELECT grant, so on
   a database without Supabase's default privileges an admin could not rename
   a system. (The same gap exists for `application_sub_statuses` and
   `candidate_sources` from 0067/0069 — it works on live only because the
   platform grants DML by default.)
5. A missing `scroll-margin-top`, so the sticky nav covered the heading.

## The limit worth knowing

**A manager who holds nothing cannot open the plan page at all.** `plans`
admits the person themselves or a `tasks.view` holder (0006), so the database
rule permitting a manager to keep the list has nowhere to be exercised from.
The section is gated on `tasks.view` to match what is actually reachable.

Making the manager path real needs two things that are the maintainer's
decisions, not this slice's: managers recorded on employments (**0 of the live
employments name one today**), and the `plans` policy widened to admit them.
Until then this is IT's list — on live, Naum and Olivera hold `it.assign`.
