import { describe, expect, it } from 'vitest'
import {
  JOB_STEPS,
  currentStep,
  jobStatusActions,
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

describe('jobStatusActions', () => {
  it('offers Mark ready only when a description exists', () => {
    expect(jobStatusActions({ status: 'draft', hasDescription: false })).toEqual([])
    expect(jobStatusActions({ status: 'draft', hasDescription: true })).toEqual([
      { to: 'ready', label: 'Mark ready' },
    ])
  })

  it('lets a ready job open without a channel, and an open job pause or close', () => {
    expect(jobStatusActions({ status: 'ready', hasDescription: true })).toEqual([
      { to: 'open', label: 'Open job' },
    ])
    expect(jobStatusActions({ status: 'open', hasDescription: true })).toEqual([
      { to: 'on_hold', label: 'Put on hold' },
      { to: 'closed', label: 'Close job' },
    ])
  })

  it('lets a paused or closed job reopen; a filled job only closes', () => {
    expect(jobStatusActions({ status: 'on_hold', hasDescription: true })).toEqual([
      { to: 'open', label: 'Reopen' },
      { to: 'closed', label: 'Close job' },
    ])
    expect(jobStatusActions({ status: 'closed', hasDescription: true })).toEqual([{ to: 'open', label: 'Reopen' }])
    expect(jobStatusActions({ status: 'filled', hasDescription: true })).toEqual([{ to: 'closed', label: 'Close job' }])
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
