import { describe, expect, it } from 'vitest'
import {
  STAGES,
  STAGE_LABEL,
  closureLine,
  contactHint,
  firstOpenStatus,
  filterStagesFor,
  liveStatuses,
  noStatusesHint,
  pickableStatusGroups,
  statusChangeLine,
  statusEventTitle,
  statusFilterGroups,
  statusLabels,
  statusesByOutcome,
} from './stageStatuses'
import type { SubStatusRow } from './hiringLabels'

const rows: SubStatusRow[] = [
  { key: 'interview_stakeholders', stage_key: 'interview', outcome: 'open', label: 'Interview 2 – Stakeholders', sort_order: 50, archived_at: null },
  { key: 'interview_hr', stage_key: 'interview', outcome: 'open', label: 'Interview 1 – HR', sort_order: 40, archived_at: null },
  { key: 'no_show', stage_key: 'interview', outcome: 'open', label: 'No-show', sort_order: 130, archived_at: '2026-10-08T10:00:00Z' },
  { key: 'contacted', stage_key: 'screening', outcome: 'open', label: 'In conversation', sort_order: 10, archived_at: null },
  { key: 'job_closed', stage_key: 'offer', outcome: 'withdrew', label: 'Job closed', sort_order: 70, archived_at: null },
]

describe('STAGES', () => {
  it('is Zoho’s four stages, in pipeline order', () => {
    expect(STAGES).toEqual(['screening', 'interview', 'offer', 'hired'])
  })

  it('labels the offer stage Offered', () => {
    expect(STAGE_LABEL.offer).toBe('Offered')
    expect(STAGE_LABEL.screening).toBe('Screening')
  })
})

describe('statusesByOutcome', () => {
  const outcomes: SubStatusRow[] = [
    { key: 'rejected_general', stage_key: 'offer', outcome: 'rejected', label: 'Rejected', sort_order: 10, archived_at: null },
    { key: 'rejected_for_interview', stage_key: 'interview', outcome: 'rejected', label: 'Rejected for interview', sort_order: 90, archived_at: null },
    { key: 'unqualified', stage_key: 'screening', outcome: 'rejected', label: 'Unqualified', sort_order: 80, archived_at: null },
    { key: 'old_reject', stage_key: 'screening', outcome: 'rejected', label: 'Old', sort_order: 1, archived_at: '2026-10-08T10:00:00Z' },
    { key: 'withdrew_self', stage_key: 'screening', outcome: 'withdrew', label: 'Withdrew', sort_order: 5, archived_at: null },
    { key: 'contacted', stage_key: 'screening', outcome: 'open', label: 'Contacted', sort_order: 1, archived_at: null },
  ]

  it('lists the live statuses with that outcome, in stage order then sort order', () => {
    expect(statusesByOutcome(outcomes, 'rejected').map((s) => s.key)).toEqual(['unqualified', 'rejected_for_interview', 'rejected_general'])
    expect(statusesByOutcome(outcomes, 'withdrew').map((s) => s.key)).toEqual(['withdrew_self'])
    expect(statusesByOutcome(outcomes, 'hired')).toEqual([])
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
    expect(groups.map((g) => g.stageKey)).toEqual(['screening', 'interview', 'offer'])
    expect(groups[1].options.map((o) => o.key)).toEqual(['interview_hr', 'interview_stakeholders', 'no_show'])
  })

  it('keeps a retired status findable, marked as retired', () => {
    expect(statusFilterGroups(rows)[1].options[2].label).toBe('No-show (retired)')
  })

  it('narrows to the stages asked for', () => {
    expect(statusFilterGroups(rows, ['interview']).map((g) => g.stageKey)).toEqual(['interview'])
    expect(statusFilterGroups(rows, ['screening', 'interview']).map((g) => g.stageKey)).toEqual(['screening', 'interview'])
    expect(statusFilterGroups(rows, ['hired'])).toEqual([])
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
  it('calls it outreach at Screening and a status elsewhere', () => {
    expect(statusEventTitle('screening')).toBe('Outreach')
    expect(statusEventTitle('interview')).toBe('Status')
    expect(statusEventTitle('offer')).toBe('Status')
  })
})

describe('noStatusesHint', () => {
  it('says where an admin adds the first one', () => {
    expect(noStatusesHint('Offer')).toBe('No statuses at Offer yet. An admin adds them under Hiring → Labels.')
  })
})

describe('filterStagesFor', () => {
  it('offers only statuses the list can show', () => {
    expect(filterStagesFor('live')).toEqual(['screening', 'interview', 'offer'])
    expect(filterStagesFor('not_responding')).toEqual(['screening'])
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

describe('pickableStatusGroups', () => {
  const pickable: SubStatusRow[] = [
    ...rows,
    { key: 'hired', stage_key: 'hired', outcome: 'hired', label: 'Hired', sort_order: 10, archived_at: null },
    { key: 'rejected_by_hr', stage_key: 'interview', outcome: 'rejected', label: 'Rejected by HR', sort_order: 200, archived_at: null },
  ]

  it('groups every live status by stage, leaving out retired ones and Hired', () => {
    expect(pickableStatusGroups(pickable)).toEqual([
      { stageKey: 'screening', stageLabel: 'Screening', options: [{ key: 'contacted', label: 'In conversation' }] },
      {
        stageKey: 'interview',
        stageLabel: 'Interview',
        options: [
          { key: 'interview_hr', label: 'Interview 1 – HR' },
          { key: 'interview_stakeholders', label: 'Interview 2 – Stakeholders' },
          { key: 'rejected_by_hr', label: 'Rejected by HR' },
        ],
      },
      { stageKey: 'offer', stageLabel: 'Offered', options: [{ key: 'job_closed', label: 'Job closed' }] },
    ])
  })

  it('narrows to one outcome when asked', () => {
    expect(pickableStatusGroups(pickable, 'rejected')).toEqual([
      { stageKey: 'interview', stageLabel: 'Interview', options: [{ key: 'rejected_by_hr', label: 'Rejected by HR' }] },
    ])
  })
})

describe('firstOpenStatus', () => {
  const stageRows: SubStatusRow[] = [
    { key: 'rejected_by_hr', stage_key: 'interview', outcome: 'rejected', label: 'Rejected by HR', sort_order: 5, archived_at: null },
    { key: 'interview_scheduled', stage_key: 'interview', outcome: 'open', label: 'Interview-Scheduled', sort_order: 20, archived_at: null },
    { key: 'interview_to_schedule', stage_key: 'interview', outcome: 'open', label: 'Interview-to-be-Scheduled', sort_order: 10, archived_at: null },
    { key: 'old_first', stage_key: 'interview', outcome: 'open', label: 'Old', sort_order: 1, archived_at: '2026-10-01T00:00:00Z' },
  ]

  it('is the stage’s first live status that keeps the application open', () => {
    expect(firstOpenStatus(stageRows, 'interview')?.key).toBe('interview_to_schedule')
  })

  it('is null when the stage has none', () => {
    expect(firstOpenStatus(stageRows, 'offer')).toBeNull()
  })
})

describe('closureLine', () => {
  it('reads the reason and the day the job closed it', () => {
    expect(closureLine('2026-11-06T09:30:00Z', 'Position filled.')).toBe('Job closed — Position filled (2026-11-06)')
  })

  it('leaves the reason out when there is none', () => {
    expect(closureLine('2026-11-06T09:30:00Z', null)).toBe('Job closed (2026-11-06)')
    expect(closureLine('2026-11-06T09:30:00Z', '  ')).toBe('Job closed (2026-11-06)')
  })

  it('is null for an application nothing closed', () => {
    expect(closureLine(null, 'Position filled.')).toBeNull()
  })
})
