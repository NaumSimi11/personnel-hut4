import { describe, expect, it } from 'vitest'
import {
  STATUS_STAGES,
  contactHint,
  filterStagesFor,
  liveStatuses,
  noStatusesHint,
  reasonFor,
  statusChangeLine,
  statusEventTitle,
  statusFilterGroups,
  statusLabels,
} from './stageStatuses'
import type { SubStatusRow } from './outreach'

const rows: SubStatusRow[] = [
  { key: 'interview_stakeholders', stage_key: 'interview', label: 'Interview 2 – Stakeholders', sort_order: 50, archived_at: null },
  { key: 'interview_hr', stage_key: 'interview', label: 'Interview 1 – HR', sort_order: 40, archived_at: null },
  { key: 'no_show', stage_key: 'interview', label: 'No-show', sort_order: 130, archived_at: '2026-10-08T10:00:00Z' },
  { key: 'contacted', stage_key: 'screening', label: 'In conversation', sort_order: 10, archived_at: null },
  { key: 'job_closed', stage_key: 'withdrawn', label: 'Job closed', sort_order: 70, archived_at: null },
]

describe('STATUS_STAGES', () => {
  it('is every stage, in pipeline order, withdrawn last', () => {
    expect(STATUS_STAGES).toEqual(['new', 'screening', 'interview', 'offer', 'hired', 'rejected', 'withdrawn'])
  })
})

describe('statusLabels', () => {
  it('names every status, retired ones too, so an old application still reads', () => {
    const labels = statusLabels(rows)
    expect(labels.interview_hr).toBe('Interview 1 – HR')
    expect(labels.no_show).toBe('No-show (retired)')
    expect(Object.keys(labels)).toHaveLength(rows.length)
  })
})

describe('liveStatuses', () => {
  it('drops the retired and sorts by stage, then by sort order', () => {
    expect(liveStatuses(rows).map((s) => s.key)).toEqual(['contacted', 'interview_hr', 'interview_stakeholders', 'job_closed'])
  })

  it('returns the trimmed shape components pass around', () => {
    expect(liveStatuses(rows)[0]).toEqual({ key: 'contacted', stage_key: 'screening', label: 'In conversation', sort_order: 10 })
  })
})

describe('statusFilterGroups', () => {
  it('groups by stage in pipeline order and skips a stage with nothing', () => {
    const groups = statusFilterGroups(rows)
    expect(groups.map((g) => g.stageKey)).toEqual(['screening', 'interview', 'withdrawn'])
    expect(groups[1].options.map((o) => o.key)).toEqual(['interview_hr', 'interview_stakeholders', 'no_show'])
  })

  it('keeps a retired status findable, marked as retired', () => {
    expect(statusFilterGroups(rows)[1].options[2].label).toBe('No-show (retired)')
  })

  it('narrows to the stages asked for', () => {
    expect(statusFilterGroups(rows, ['interview']).map((g) => g.stageKey)).toEqual(['interview'])
    expect(statusFilterGroups(rows, ['screening', 'interview']).map((g) => g.stageKey)).toEqual(['screening', 'interview'])
    expect(statusFilterGroups(rows, ['offer'])).toEqual([])
  })

  it('names the stage the way the rest of the app does', () => {
    expect(statusFilterGroups(rows)[0].stageLabel).toBe('Screening')
  })
})

describe('statusChangeLine', () => {
  const labels = statusLabels(rows)

  it('names both sides and appends the note', () => {
    expect(statusChangeLine({ from_sub_status_key: 'interview_hr', to_sub_status_key: 'interview_stakeholders', body: 'Second round' }, labels)).toBe(
      'Status: Interview 1 – HR → Interview 2 – Stakeholders · Second round',
    )
  })

  it('shows — for an application that had none, and omits an empty note', () => {
    expect(statusChangeLine({ from_sub_status_key: null, to_sub_status_key: 'interview_hr', body: null }, labels)).toBe('Status: — → Interview 1 – HR')
  })

  it('falls back to the raw key for a status it cannot name', () => {
    expect(statusChangeLine({ from_sub_status_key: null, to_sub_status_key: 'mystery', body: '' }, labels)).toBe('Status: — → mystery')
  })
})

describe('statusEventTitle', () => {
  it('calls it outreach at New and Screening and a status elsewhere', () => {
    expect(statusEventTitle('new')).toBe('Outreach')
    expect(statusEventTitle('screening')).toBe('Outreach')
    expect(statusEventTitle('interview')).toBe('Status')
    expect(statusEventTitle('withdrawn')).toBe('Status')
  })
})

describe('noStatusesHint', () => {
  it('says where an admin adds the first one', () => {
    expect(noStatusesHint('Offer')).toBe('No statuses at Offer yet. An admin adds them under Hiring → Labels.')
  })
})

describe('reasonFor', () => {
  it('keeps the note as the reason when there is one', () => {
    expect(reasonFor('Rejected by HR', '  Salary far apart. ')).toBe('Salary far apart.')
  })

  it('falls back to the status itself', () => {
    expect(reasonFor('Rejected by HR', '   ')).toBe('Rejected by HR')
  })
})

describe('filterStagesFor', () => {
  it('offers only statuses the list can show', () => {
    expect(filterStagesFor('live')).toEqual(['new', 'screening', 'interview', 'offer'])
    expect(filterStagesFor('not_responding')).toEqual(['new', 'screening'])
    expect(filterStagesFor('interview')).toEqual(['interview'])
  })

  it('offers everything for all stages', () => {
    expect(filterStagesFor('all')).toBeUndefined()
  })
})

describe('contactHint', () => {
  it('warns that Do not contact is a label, not the block', () => {
    expect(contactHint('do_not_contact')).toBe(
      'This only labels the application. To stop anyone contacting this person, set Do not contact on their candidate record.',
    )
  })

  it('says nothing for any other status', () => {
    expect(contactHint('job_closed')).toBeNull()
    expect(contactHint('')).toBeNull()
  })
})
