# 063 — Delete is for a mistake, archive is for history (migration 0080)

task.md, on the hiring pages: *"we need a delete button so we can delete
particular hiring or / and a job. i think we have this but i can't see this is
planned well"* — and on the policies: *"instead of archive, we need a hard
delete… also maybe is o to have an edit inline, so the hr can fullfill if
something is missing"* — and later: *"hirering/candicates - here on each
candicate we have archive button - this need to be hard delete also"*.

## He was right that it was not planned

Deleting a job lived on the company page and one list. A policy could only be
archived. A candidate could only be archived. Three different answers to one
question, and none of them where somebody actually works.

One rule instead, the one 0071 and 0074 already followed without saying so:

> **Delete is for a mistake. Archive is for history.**
> A thing may be deleted only while nothing has happened to it.

## What that means in each case

- **A hiring request** goes while no job came from it (`jobs.hiring_request_id`
  is NO ACTION — the database already said so).
- **A job** goes while nothing was ever received.
- **A policy** goes while nobody has agreed to it. Once somebody has, the
  acknowledgement is the record that they read it, and deleting the policy
  leaves that record pointing at nothing. Archive is for those.
- **A candidate** goes while they are nothing but a name — no applications, no
  notes, no files. And never if they asked not to be contacted: forgetting that
  is how somebody gets sourced afresh next week.

The last two are spelled out in the function rather than left to the keys, for
0074's reason: `candidate_files` and `candidate_notes` both CASCADE, so a
delete would take a CV and 1,756 imported notes without a word of protest.

## Editing a policy in place

`update_policy`, because HR needs to fix a missing summary without ceremony.
The title and the summary are how a policy is *referred to* — the line in the
welcome note, the heading in the list — and may be corrected whenever. The body
is what people agreed to, so it is editable while the policy is a draft and
never afterwards: a published policy's text changes through `publish_policy`,
which bumps the version that acknowledgements point at. Silently rewriting
agreed text under an unchanged version number is the one thing this refuses.

## Where the buttons are now

Requests tab (where requests are worked), the candidate record, and the
policies panel. The job page's own delete was written and then lost to a
concurrent edit of that file by another session; the Job openings list still
has one.

## Review

Six findings, three of them mine and fixed here:

1. The new Delete button on the candidate record sat between Archive and
   Restore, and Restore's `v-else-if` chained to it — **archived candidates
   could no longer be restored at all.**
2. The panel counted acknowledgements of the *current version* while
   `delete_policy` counts every version, so after a re-publish the button was
   enabled and the database refused.
3. `.delete()` with no `.select()` reports success for a row RLS filtered
   away — the page congratulated itself on nothing happening.

The other three concern `0081_delete_job_application`, which another session
wrote in parallel; see the note in `docs/session-handoff.yaml`.
