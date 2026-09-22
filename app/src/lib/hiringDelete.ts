/**
 * Whether a hiring request or a job may be deleted from the company page
 * (task.md: "company - hiring. we need to be able to delete").
 *
 * The database already refuses the dangerous cases — `applications.job_id` and
 * `jobs.hiring_request_id` are both NO ACTION, so a job with applicants and a
 * request that became a job cannot be deleted however hard anyone tries. These
 * rules only let the page say so *before* the click, instead of turning a
 * foreign-key error into a shrug. `friendlyDeleteError` is the backstop for the
 * race where the last applicant arrives between the page load and the click.
 */

export type DeleteVerdict = { canDelete: boolean; reason: string | null }

const ALLOWED: DeleteVerdict = { canDelete: true, reason: null }
const NOT_ALLOWED = 'You do not have permission to delete this.'

/** A job goes only while nothing has been received against it. */
export function jobDeletable(job: { applications: number }, permitted: boolean): DeleteVerdict {
  if (!permitted) return { canDelete: false, reason: NOT_ALLOWED }
  if (job.applications > 0) {
    const n = job.applications
    return {
      canDelete: false,
      reason: `${n} application${n === 1 ? '' : 's'} came in for this job, so it cannot be deleted. Close it instead.`,
    }
  }
  return ALLOWED
}

/** A request goes only while it has not been approved into a job. */
export function requestDeletable(request: { hasJob: boolean }, permitted: boolean): DeleteVerdict {
  if (!permitted) return { canDelete: false, reason: NOT_ALLOWED }
  if (request.hasJob) {
    return { canDelete: false, reason: 'A job was opened from this request, so it cannot be deleted. Delete the job first.' }
  }
  return ALLOWED
}

/** A foreign-key refusal in words the page can show; anything else is passed through. */
export function friendlyDeleteError(message: string): string {
  if (/foreign key|violates foreign key constraint/i.test(message)) {
    return 'Something is already attached to this, so it cannot be deleted. Reload the page to see what changed.'
  }
  if (/row-level security/i.test(message)) return NOT_ALLOWED
  return message
}
