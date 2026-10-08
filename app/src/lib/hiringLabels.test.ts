import { describe, expect, it } from 'vitest'
import {
  KEY_PATTERN,
  MAX_LABEL_LENGTH,
  canRetire,
  duplicateLabel,
  groupByStage,
  keyFromLabel,
  labelChanged,
  nextSortOrder,
  normaliseLabel,
  validateLabel,
} from './hiringLabels'

describe('validateLabel', () => {
  it('refuses an empty label, however it is spelled', () => {
    expect(validateLabel('')).toBe('A label cannot be empty.')
    expect(validateLabel('   ')).toBe('A label cannot be empty.')
    expect(validateLabel('\t\n')).toBe('A label cannot be empty.')
  })

  it('refuses a label past the length the lists can show', () => {
    expect(validateLabel('x'.repeat(MAX_LABEL_LENGTH + 1))).toBe(
      `A label can be at most ${MAX_LABEL_LENGTH} characters.`,
    )
  })

  it('accepts a normal label, and one exactly at the limit', () => {
    expect(validateLabel('Interested')).toBeNull()
    expect(validateLabel('x'.repeat(MAX_LABEL_LENGTH))).toBeNull()
  })

  it('measures what will be stored, so surrounding space never fails a valid label', () => {
    expect(validateLabel(`  ${'x'.repeat(MAX_LABEL_LENGTH)}  `)).toBeNull()
  })
})

describe('normaliseLabel', () => {
  it('stores the trimmed text', () => {
    expect(normaliseLabel('  In conversation  ')).toBe('In conversation')
  })
})

describe('labelChanged', () => {
  it('is false when only surrounding space differs, so a no-op never writes', () => {
    expect(labelChanged('Interested', '  Interested  ')).toBe(false)
    expect(labelChanged('Interested', 'Interested')).toBe(false)
  })

  it('is true for a real edit, including a change of case', () => {
    expect(labelChanged('Interested', 'Keen')).toBe(true)
    expect(labelChanged('Interested', 'interested')).toBe(true)
  })
})

describe('groupByStage', () => {
  const rows = [
    { key: 'qualified', stage_key: 'screening', label: 'Qualified', sort_order: 40, archived_at: null },
    { key: 'applied', stage_key: 'new', label: 'Applied', sort_order: 10, archived_at: null },
    { key: 'contacted', stage_key: 'screening', label: 'In conversation', sort_order: 10, archived_at: null },
    { key: 'sourced', stage_key: 'new', label: 'Sourced', sort_order: 20, archived_at: null },
    { key: 'no_show', stage_key: 'interview', label: 'No-show', sort_order: 130, archived_at: '2026-10-08T10:00:00Z' },
  ]

  it('lists every stage in pipeline order, even one with nothing yet, so HR can add the first', () => {
    const groups = groupByStage(rows)
    expect(groups.map((g) => g.stageKey)).toEqual(['new', 'screening', 'interview', 'offer', 'hired', 'rejected', 'withdrawn'])
    expect(groups[3].rows).toEqual([])
  })

  it('keeps each stage in sort order', () => {
    const groups = groupByStage(rows)
    expect(groups[0].rows.map((r) => r.key)).toEqual(['applied', 'sourced'])
    expect(groups[1].rows.map((r) => r.key)).toEqual(['contacted', 'qualified'])
  })

  it('puts a retired status aside, where it can be restored', () => {
    const interview = groupByStage(rows)[2]
    expect(interview.rows).toEqual([])
    expect(interview.retired.map((r) => r.key)).toEqual(['no_show'])
  })

  it('names each stage the way the rest of the app names it', () => {
    // stageLabel() calls the `new` stage "Applied" everywhere else; the panel
    // follows it rather than inventing a second name for the same stage.
    expect(groupByStage(rows)[0].stageLabel).toBe('Applied')
  })

  it('keeps an unknown stage rather than dropping its rows', () => {
    const groups = groupByStage([{ key: 'x', stage_key: 'mystery', label: 'X', sort_order: 1, archived_at: null }])
    expect(groups.map((g) => g.stageKey).at(-1)).toBe('mystery')
  })
})

describe('keyFromLabel', () => {
  it('turns a name into a key the database accepts', () => {
    expect(keyFromLabel('Interview 3 – Final round!', new Set())).toBe('interview_3_final_round')
  })

  it('drops accents rather than the letters under them', () => {
    expect(keyFromLabel('Évaluation finale', new Set())).toBe('evaluation_finale')
  })

  it('starts with a letter, and has a fallback when nothing Latin is left', () => {
    expect(keyFromLabel('2nd call', new Set())).toBe('status_2nd_call')
    expect(keyFromLabel('Интервју', new Set())).toBe('status')
  })

  it('never reuses a key, retired ones included', () => {
    expect(keyFromLabel('No-show', new Set(['no_show']))).toBe('no_show_2')
    expect(keyFromLabel('No-show', new Set(['no_show', 'no_show_2']))).toBe('no_show_3')
    expect(keyFromLabel('Интервју', new Set(['status']))).toBe('status_2')
  })

  it('is at least two characters, as the database insists', () => {
    expect(keyFromLabel('X', new Set())).toBe('status_x')
    expect(keyFromLabel('É', new Set())).toBe('status_e')
    expect(keyFromLabel('A.', new Set())).toBe('status_a')
    expect(keyFromLabel('Ж X', new Set())).toBe('status_x')
    for (const label of ['X', 'É', 'A.', 'Ж X', '', '!!', '9']) {
      expect(keyFromLabel(label, new Set()), label).toMatch(KEY_PATTERN)
    }
  })

  it('stays within forty characters, suffix and all', () => {
    const long = 'a'.repeat(60)
    expect(keyFromLabel(long, new Set())).toMatch(/^[a-z][a-z0-9_]{1,39}$/)
    expect(keyFromLabel(long, new Set(['a'.repeat(40)]))).toMatch(/^[a-z][a-z0-9_]{1,39}$/)
  })
})

describe('duplicateLabel', () => {
  const stage = [
    { key: 'interview_hr', stage_key: 'interview', label: 'Interview 1 – HR', sort_order: 40, archived_at: null },
    { key: 'no_show', stage_key: 'interview', label: 'No-show', sort_order: 130, archived_at: '2026-10-08T10:00:00Z' },
  ]

  it('refuses a name a live status of the stage already has, ignoring case and space', () => {
    expect(duplicateLabel('  interview 1 – hr ', stage)).toBe('“Interview 1 – HR” is already a status at this stage.')
  })

  it('lets a status keep its own name, and a retired one be reused', () => {
    expect(duplicateLabel('Interview 1 – HR', stage, 'interview_hr')).toBeNull()
    expect(duplicateLabel('No-show', stage)).toBeNull()
  })
})

describe('nextSortOrder', () => {
  it('goes after everything at the stage, retired included', () => {
    expect(nextSortOrder([{ sort_order: 40 }, { sort_order: 130 }])).toBe(140)
  })

  it('starts at 10 for an empty stage', () => {
    expect(nextSortOrder([])).toBe(10)
  })
})

describe('canRetire', () => {
  it('refuses the four statuses the rules name, as the database does', () => {
    for (const key of ['applied', 'sourced', 'contact_attempted', 'contacted']) expect(canRetire(key), key).toBe(false)
  })

  it('lets every other status go', () => {
    expect(canRetire('interested')).toBe(true)
    expect(canRetire('job_closed')).toBe(true)
  })
})
