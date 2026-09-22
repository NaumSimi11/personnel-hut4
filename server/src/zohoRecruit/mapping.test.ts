import { describe, expect, it } from 'vitest'
import {
  DEPARTMENT_TO_COMPANY,
  JOB_STATUS_TO_STATUS,
  SOURCE_TO_KEY,
  STATUS_TO_STAGE,
  mapDepartment,
  mapJobStatus,
  mapSource,
  mapStatus,
  notePrefix,
  rewriteMentions,
  staleRule,
} from './mapping.js'

// The 38 distinct `Candidate Status` values of Associated_001.csv, byte-exact.
const STATUSES: Record<string, string> = {
  Contacted: 'screening',
  Interested: 'screening',
  Qualified: 'screening',
  'Waiting-for-Evaluation': 'screening',
  Associated: 'new',
  New: 'new',
  'Attempted to Contact': 'new',
  'Not Contacted': 'new',
  'Not contacted': 'new',
  'Not Interested': 'withdrawn',
  'Not responding': 'withdrawn',
  'Withdraw Application': 'withdrawn',
  'NEVER to be contacted again': 'withdrawn',
  'Contact in Future': 'withdrawn',
  'Offer-Declined': 'withdrawn',
  Rejected: 'rejected',
  'Rejected by hiring manager': 'rejected',
  'Rejected by HR': 'rejected',
  'Rejected by Manager - Interview': 'rejected',
  'Rejected-for-Interview': 'rejected',
  Unqualified: 'rejected',
  'Offer-Withdrawn': 'rejected',
  'Rejected-Hirable': 'rejected',
  'On-Hold': 'interview',
  'Interview 1 - HR': 'interview',
  'Interview 2 - Stakeholders': 'interview',
  'Interview 3 - Other stakeholder': 'interview',
  'Interview 4 - Other stakeholders': 'interview',
  'Feedback to be provided from an Interview': 'interview',
  'Interview-Scheduled': 'interview',
  'Interview-to-be-Scheduled': 'interview',
  'Interview-in-Progress': 'interview',
  'Submitted-to-hiring manager': 'interview',
  Task: 'interview',
  'No-Show': 'interview',
  'Offer-Made': 'offer',
  'To-be-Offered': 'offer',
  Hired: 'hired',
}

describe('mapStatus', () => {
  it('maps every one of the 38 association statuses', () => {
    expect(Object.keys(STATUSES)).toHaveLength(38)
    expect(Object.keys(STATUS_TO_STAGE).sort()).toEqual(Object.keys(STATUSES).sort())
    for (const [status, stage] of Object.entries(STATUSES)) {
      expect(mapStatus(status).stage, status).toBe(stage)
    }
  })

  it('carries the reason text and the contact flags', () => {
    expect(mapStatus('Not Interested')).toEqual({ stage: 'withdrawn', reason: 'Not interested' })
    expect(mapStatus('Not responding')).toEqual({ stage: 'withdrawn', reason: 'No response' })
    expect(mapStatus('Withdraw Application')).toEqual({ stage: 'withdrawn', reason: 'Candidate withdrew' })
    expect(mapStatus('NEVER to be contacted again')).toEqual({ stage: 'withdrawn', reason: 'Do not contact', flag: 'do_not_contact' })
    expect(mapStatus('Contact in Future')).toEqual({ stage: 'withdrawn', reason: 'Contact in future', flag: 'contact_later' })
    expect(mapStatus('Offer-Declined')).toEqual({ stage: 'withdrawn', reason: 'Offer declined' })
    expect(mapStatus('Rejected')).toEqual({ stage: 'rejected', reason: 'Rejected' })
    expect(mapStatus('Rejected by hiring manager')).toEqual({ stage: 'rejected', reason: 'Rejected by the hiring manager' })
    expect(mapStatus('Rejected by HR')).toEqual({ stage: 'rejected', reason: 'Rejected by HR' })
    expect(mapStatus('Rejected by Manager - Interview')).toEqual({ stage: 'rejected', reason: 'Rejected by the manager after interview' })
    expect(mapStatus('Rejected-for-Interview')).toEqual({ stage: 'rejected', reason: 'Rejected for interview' })
    expect(mapStatus('Unqualified')).toEqual({ stage: 'rejected', reason: 'Unqualified' })
    expect(mapStatus('Offer-Withdrawn')).toEqual({ stage: 'rejected', reason: 'Offer withdrawn' })
    expect(mapStatus('Rejected-Hirable')).toEqual({ stage: 'rejected', reason: 'Rejected, hirable later', flag: 'contact_later' })
    expect(mapStatus('Contacted')).toEqual({ stage: 'screening', sub: 'contacted' })
  })

  it('carries the D5 outreach sub-status backfill (plan 054); every other mapped status has none', () => {
    const withSub: Record<string, string> = {
      Associated: 'sourced',
      New: 'sourced',
      'Attempted to Contact': 'contact_attempted',
      'Not Contacted': 'contact_attempted',
      'Not contacted': 'contact_attempted',
      Contacted: 'contacted',
      Interested: 'interested',
      'Waiting-for-Evaluation': 'awaiting_evaluation',
      Qualified: 'qualified',
    }
    for (const [status, sub] of Object.entries(withSub)) {
      expect(mapStatus(status).sub, status).toBe(sub)
    }
    for (const status of Object.keys(STATUSES).filter((s) => !(s in withSub))) {
      expect(mapStatus(status).sub, status).toBeUndefined()
    }
  })

  it('is byte-exact: an unknown status throws, never guesses', () => {
    expect(() => mapStatus('Not  Contacted')).toThrow(/unknown zoho status/i)
    expect(() => mapStatus('not contacted')).toThrow(/unknown zoho status/i)
    expect(() => mapStatus('Rejected–Hirable')).toThrow(/unknown zoho status/i)
    expect(() => mapStatus('')).toThrow(/unknown zoho status/i)
    expect(() => mapStatus('Approved by hiring manager')).toThrow(/unknown zoho status/i)
  })
})

describe('mapSource', () => {
  it('maps the 10 source values', () => {
    expect(Object.keys(SOURCE_TO_KEY)).toHaveLength(10)
    expect(mapSource('Head Hunt')).toBe('head_hunt')
    expect(mapSource('Imported using Resume Extractor')).toBe('linkedin_profile')
    expect(mapSource('Advertisement Linkedin')).toBe('linkedin_ad')
    expect(mapSource('CareerSite')).toBe('careers_page')
    expect(mapSource('Advertisement External Career Pages')).toBe('job_board')
    expect(mapSource('Advertisement')).toBe('job_board')
    expect(mapSource('Employee Referral')).toBe('referral')
    expect(mapSource('External Referral')).toBe('referral')
    expect(mapSource('Added by User')).toBe('added_by_hand')
    expect(mapSource('None')).toBe('imported')
    expect(mapSource('')).toBe('imported')
  })

  it('throws on an unknown source', () => {
    expect(() => mapSource('LinkedIn')).toThrow(/unknown zoho source/i)
    expect(() => mapSource('head hunt')).toThrow(/unknown zoho source/i)
  })
})

describe('mapDepartment', () => {
  it('maps the eleven departments per D1', () => {
    expect(Object.keys(DEPARTMENT_TO_COMPANY)).toHaveLength(11)
    for (const name of ['HUT 4', 'HUT 4 Capital', 'Corporate Services', 'Corporate Marketing', 'Multihem']) {
      expect(mapDepartment(name), name).toBe('HUT4')
    }
    for (const name of ['SYNAMI DOOEL', 'Synami Products', 'Synami Sales']) {
      expect(mapDepartment(name), name).toBe('SYNA')
    }
    expect(mapDepartment('SNOWBALL')).toBe('SNOW')
    expect(mapDepartment('Liquiditas')).toBe('LIQU')
    expect(mapDepartment('Clip Media Group')).toBeNull()
  })

  it('reports an unknown department as undefined, so the extract can count it', () => {
    expect(mapDepartment('Hut 4')).toBeUndefined()
    expect(mapDepartment('')).toBeUndefined()
  })
})

describe('mapJobStatus', () => {
  it('maps the four job statuses', () => {
    expect(Object.keys(JOB_STATUS_TO_STATUS)).toHaveLength(4)
    expect(mapJobStatus('Filled')).toBe('filled')
    expect(mapJobStatus('Cancelled')).toBe('closed')
    expect(mapJobStatus('In-progress')).toBe('open')
    expect(mapJobStatus('Inactive')).toBe('on_hold')
  })

  it('throws on an unknown job status', () => {
    expect(() => mapJobStatus('Open')).toThrow(/unknown zoho job status/i)
  })
})

describe('staleRule', () => {
  const filled = { status: 'Filled', dateClosed: '2024-03-01T00:00:00.000Z', modifiedAt: '2024-05-09T10:00:00.000Z' }
  const cancelled = { status: 'Cancelled', dateClosed: null, modifiedAt: '2024-05-09T10:00:00.000Z' }
  const open = { status: 'In-progress', dateClosed: null, modifiedAt: '2024-05-09T10:00:00.000Z' }
  const inactive = { status: 'Inactive', dateClosed: null, modifiedAt: '2024-05-09T10:00:00.000Z' }

  it('withdraws a non-terminal stage on a Filled job, dated the job close', () => {
    expect(staleRule('screening', filled)).toEqual({
      stale_closed: true,
      withdrawn_reason: 'Job closed',
      close_date: '2024-03-01T00:00:00.000Z',
      close_date_assumed: false,
    })
  })

  it('falls back to the Modified Time on a Cancelled job and says so', () => {
    expect(staleRule('interview', cancelled)).toEqual({
      stale_closed: true,
      withdrawn_reason: 'Job closed',
      close_date: '2024-05-09T10:00:00.000Z',
      close_date_assumed: true,
    })
    expect(staleRule('new', cancelled).stale_closed).toBe(true)
  })

  it('leaves terminal stages and live jobs alone', () => {
    expect(staleRule('hired', filled)).toEqual({ stale_closed: false })
    expect(staleRule('rejected', cancelled)).toEqual({ stale_closed: false })
    expect(staleRule('withdrawn', filled)).toEqual({ stale_closed: false })
    expect(staleRule('screening', open)).toEqual({ stale_closed: false })
    expect(staleRule('interview', inactive)).toEqual({ stale_closed: false })
  })
})

describe('rewriteMentions', () => {
  const users = new Map([['Zrecruit_12345678901234567', 'Kristina Arsova']])

  it('turns a Zoho mention token into @Full Name', () => {
    expect(rewriteMentions('recruit[user#12345678901234567#98765432101]recruit please call', users))
      .toBe('@Kristina Arsova please call')
  })

  it('keeps an unknown user readable', () => {
    expect(rewriteMentions('ask recruit[user#00000000000000001#1]recruit', users)).toBe('ask @unknown user')
  })

  it('leaves text without mentions untouched', () => {
    expect(rewriteMentions('no mention here', users)).toBe('no mention here')
  })
})

describe('notePrefix', () => {
  it('formats the type, the local date and the author', () => {
    expect(notePrefix('Call', '2024-03-12T09:15:00.000Z', 'Kristina Arsova', 'Europe/Skopje'))
      .toBe('[Zoho Call · 12 Mar 2024 · Kristina Arsova]')
  })

  it('dates in the export time zone, not UTC', () => {
    // 23:30 UTC on 12 March is 00:30 on 13 March in Skopje.
    expect(notePrefix('Notes', '2024-03-12T23:30:00.000Z', 'Ada', 'Europe/Skopje'))
      .toBe('[Zoho Notes · 13 Mar 2024 · Ada]')
  })
})
