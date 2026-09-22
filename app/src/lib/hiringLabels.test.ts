import { describe, expect, it } from 'vitest'
import {
  MAX_LABEL_LENGTH,
  groupByStage,
  labelChanged,
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
    { key: 'qualified', stage_key: 'screening', label: 'Qualified', sort_order: 40 },
    { key: 'applied', stage_key: 'new', label: 'Applied', sort_order: 10 },
    { key: 'contacted', stage_key: 'screening', label: 'In conversation', sort_order: 10 },
    { key: 'sourced', stage_key: 'new', label: 'Sourced', sort_order: 20 },
  ]

  it('groups by stage in pipeline order, each group in sort order', () => {
    const groups = groupByStage(rows)
    expect(groups.map((g) => g.stageKey)).toEqual(['new', 'screening'])
    expect(groups[0].rows.map((r) => r.key)).toEqual(['applied', 'sourced'])
    expect(groups[1].rows.map((r) => r.key)).toEqual(['contacted', 'qualified'])
  })

  it('names each stage the way the rest of the app names it', () => {
    // stageLabel() calls the `new` stage "Applied" everywhere else; the panel
    // follows it rather than inventing a second name for the same stage.
    expect(groupByStage(rows)[0].stageLabel).toBe('Applied')
  })

  it('keeps an unknown stage rather than dropping its rows', () => {
    const groups = groupByStage([{ key: 'x', stage_key: 'mystery', label: 'X', sort_order: 1 }])
    expect(groups.map((g) => g.stageKey)).toEqual(['mystery'])
  })
})
