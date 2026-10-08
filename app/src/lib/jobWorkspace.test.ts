import { describe, expect, it } from 'vitest'
import {
  JOB_STEPS,
  currentStep,
  filledNote,
  friendlyRecruitmentError,
  jobHeadcount,
  jobStatusOptions,
  promotionActions,
  salvageQuestions,
  screeningQuestionsInput,
  type ChannelLite,
} from './jobWorkspace'

const live: ChannelLite = { channel_key: 'careers', status: 'live', published_revision: 1 }

describe('currentStep', () => {
  it('sits at "request" for a draft job with nothing else', () => {
    expect(currentStep({ status: 'draft', channels: [], applications: 0, hired: 0 })).toBe('request')
  })

  it('moves to "job" once the job is ready or open', () => {
    expect(currentStep({ status: 'ready', channels: [], applications: 0, hired: 0 })).toBe('job')
  })

  it('moves to "publish" once any channel is live or submitted', () => {
    expect(currentStep({ status: 'open', channels: [live], applications: 0, hired: 0 })).toBe('publish')
    expect(
      currentStep({
        status: 'open',
        channels: [{ channel_key: 'other_manual', status: 'submitted', published_revision: 1 }],
        applications: 0,
        hired: 0,
      }),
    ).toBe('publish')
  })

  it('moves to "applications" with candidates and to "hire" once someone is hired', () => {
    expect(currentStep({ status: 'open', channels: [live], applications: 2, hired: 0 })).toBe('applications')
    expect(currentStep({ status: 'filled', channels: [live], applications: 2, hired: 1 })).toBe('hire')
  })

  it('never regresses: candidates added by hand still count without a published channel', () => {
    expect(currentStep({ status: 'draft', channels: [], applications: 1, hired: 0 })).toBe('applications')
  })

  it('exposes the five prototype steps in order', () => {
    expect(JOB_STEPS.map((s) => s.id)).toEqual(['request', 'job', 'publish', 'applications', 'hire'])
  })
})

describe('jobStatusOptions', () => {
  it('offers every other status, so a job can move back or on', () => {
    expect(jobStatusOptions({ status: 'open', hasDescription: true }).map((o) => o.to)).toEqual([
      'draft',
      'ready',
      'on_hold',
      'filled',
      'closed',
    ])
    expect(jobStatusOptions({ status: 'filled', hasDescription: true }).map((o) => o.to)).toContain('open')
  })

  it('names each one the way the lists do', () => {
    expect(jobStatusOptions({ status: 'closed', hasDescription: true }).find((o) => o.to === 'on_hold')?.label).toBe('On hold')
  })

  it('keeps Ready out of reach until there is a description', () => {
    const ready = jobStatusOptions({ status: 'draft', hasDescription: false }).find((o) => o.to === 'ready')
    expect(ready?.disabled).toBe(true)
    expect(ready?.label).toBe('Ready (write the description first)')
    expect(jobStatusOptions({ status: 'draft', hasDescription: true }).find((o) => o.to === 'ready')?.disabled).toBe(false)
  })
})

describe('jobHeadcount', () => {
  it('takes the hiring request first', () => {
    expect(jobHeadcount({ request: { headcount: 3 }, custom: { zoho: { headcount: '1' } } })).toBe(3)
  })

  it('then the number Zoho kept', () => {
    expect(jobHeadcount({ request: null, custom: { zoho: { headcount: '2' } } })).toBe(2)
    expect(jobHeadcount({ request: null, custom: { zoho: { headcount: 4 } } })).toBe(4)
  })

  it('then one, for anything missing or not a positive number', () => {
    expect(jobHeadcount({ request: null, custom: null })).toBe(1)
    expect(jobHeadcount({ request: null, custom: { zoho: { headcount: 'many' } } })).toBe(1)
    expect(jobHeadcount({ request: null, custom: { zoho: { headcount: '0' } } })).toBe(1)
  })
})

describe('filledNote', () => {
  it('says nobody is left, or how many are', () => {
    expect(filledNote(0)).toBe('Filled. Nobody else is still in play.')
    expect(filledNote(1)).toBe('Filled. 1 candidate is still in play.')
    expect(filledNote(72)).toBe('Filled. 72 candidates are still in play.')
  })
})

describe('screeningQuestionsInput', () => {
  it('accepts text, yes/no and choice questions with trimmed prompts', () => {
    const parsed = screeningQuestionsInput.safeParse([
      { id: 'q1', prompt: '  Why this role? ', kind: 'text', required: true },
      { id: 'q2', prompt: 'Eligible to work in MK?', kind: 'yes_no', required: true },
      { id: 'q3', prompt: 'Notice period', kind: 'choice', required: false, options: ['Immediate', '1 month'] },
    ])
    expect(parsed.success).toBe(true)
    if (parsed.success) expect(parsed.data[0]?.prompt).toBe('Why this role?')
  })

  it('rejects a choice question with fewer than two options', () => {
    const parsed = screeningQuestionsInput.safeParse([
      { id: 'q3', prompt: 'Notice period', kind: 'choice', required: false, options: ['Immediate'] },
    ])
    expect(parsed.success).toBe(false)
    if (!parsed.success) expect(parsed.error.issues[0]?.message).toBe('Give a choice question at least two options.')
  })

  it('rejects an empty prompt', () => {
    const parsed = screeningQuestionsInput.safeParse([{ id: 'q1', prompt: ' ', kind: 'text', required: false }])
    expect(parsed.success).toBe(false)
    if (!parsed.success) expect(parsed.error.issues[0]?.message).toBe('Every question needs a prompt.')
  })
})

describe('promotionActions', () => {
  const me = 'p-me'
  const can = (caps: string[]) => (cap: string) => caps.includes(cap)

  it('offers Draft to a drafter on a request or change request', () => {
    expect(promotionActions({ status: 'requested', drafted_by: null }, me, can(['marketing.draft']))).toEqual([
      { to: 'draft', label: 'Save draft' },
    ])
    expect(
      promotionActions({ status: 'changes_requested', drafted_by: me }, me, can(['marketing.draft'])),
    ).toEqual([{ to: 'draft', label: 'Save draft' }])
  })

  it('offers Submit for review on a draft', () => {
    expect(promotionActions({ status: 'draft', drafted_by: me }, me, can(['marketing.draft']))).toEqual([
      { to: 'draft', label: 'Save draft' },
      { to: 'in_review', label: 'Submit for review' },
    ])
  })

  it('offers review actions only to an approver who is not the drafter', () => {
    expect(promotionActions({ status: 'in_review', drafted_by: me }, me, can(['marketing.approve']))).toEqual([])
    expect(
      promotionActions({ status: 'in_review', drafted_by: 'someone-else' }, me, can(['marketing.approve'])),
    ).toEqual([
      { to: 'approved', label: 'Approve' },
      { to: 'changes_requested', label: 'Request changes' },
    ])
  })

  it('offers Publish on approved content to a publisher, and nothing once published', () => {
    expect(promotionActions({ status: 'approved', drafted_by: null }, me, can(['marketing.publish']))).toEqual([
      { to: 'published', label: 'Record publication' },
    ])
    expect(promotionActions({ status: 'published', drafted_by: null }, me, can(['marketing.publish']))).toEqual([])
  })
})

describe('salvageQuestions', () => {
  it('returns a valid list unchanged', () => {
    const valid = [{ id: 'q1', prompt: 'Why?', kind: 'text', required: true }]
    expect(salvageQuestions(valid)).toEqual({ questions: valid, lossy: false })
  })

  it('repairs recoverable items instead of dropping them', () => {
    const out = salvageQuestions([{ prompt: 'Notice period', kind: 'nonsense', options: ['1 month', 2] }])
    expect(out.lossy).toBe(false)
    expect(out.questions[0]).toMatchObject({ prompt: 'Notice period', kind: 'text', required: false })
    expect(out.questions[0]?.id).toBeTruthy()
  })

  it('refuses a value that is not a list, so saving cannot wipe it', () => {
    expect(salvageQuestions({ not: 'a list' })).toEqual({ questions: [], lossy: true })
    expect(salvageQuestions(null).lossy).toBe(true)
  })
})

describe('friendlyRecruitmentError', () => {
  it('names the two capabilities that open a candidates write', () => {
    expect(friendlyRecruitmentError('new row violates row-level security policy for table "candidates"')).toBe(
      'This needs the "Work the talent pool" capability, or "Record interview feedback" where the candidate applied.',
    )
  })

  it('keeps the generic sentence for every other table', () => {
    expect(friendlyRecruitmentError('new row violates row-level security policy for table "candidate_files"')).toBe(
      'You do not have permission for this action in this company.',
    )
    expect(friendlyRecruitmentError('new row violates row-level security policy for table "jobs"')).toBe(
      'You do not have permission for this action in this company.',
    )
  })

  it('shows the sentences the RPCs speak verbatim', () => {
    expect(friendlyRecruitmentError('Ana asked not to be contacted again.')).toBe('Ana asked not to be contacted again.')
  })
})
