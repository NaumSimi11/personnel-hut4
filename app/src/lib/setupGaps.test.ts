import { describe, expect, it } from 'vitest'
import { gapLines, type SetupGaps } from './setupGaps'

const gaps = (companies: SetupGaps['companies'], can_fix = true): SetupGaps => ({ can_fix, companies })
const co = (name: string, roles: string[], inboxes: string[]) => ({
  company_id: name.toLowerCase(),
  company_name: name,
  missing_roles: roles,
  missing_inboxes: inboxes,
})

describe('gapLines', () => {
  it('is empty when nothing is missing', () => {
    expect(gapLines(gaps([]))).toEqual([])
  })

  it('puts the IT owner first, naming every company without one and what breaks', () => {
    const [it] = gapLines(gaps([co('Snowball', ['it_owner', 'hr_owner'], []), co('Synami', ['it_owner'], [])]))
    expect(it).toEqual({
      key: 'it_owner',
      strong: true,
      title: 'No IT owner',
      consequence: 'Onboarding IT lines and new IT requests reach nobody.',
      companies: [
        { id: 'snowball', name: 'Snowball', detail: null },
        { id: 'synami', name: 'Synami', detail: null },
      ],
    })
  })

  it('follows with the HR owner, then the softer inbox line', () => {
    const lines = gapLines(gaps([co('Snowball', ['hr_owner'], ['it', 'hr']), co('Hut4', [], ['hr'])]))
    expect(lines.map((l) => l.key)).toEqual(['hr_owner', 'inboxes'])
    expect(lines[0].consequence).toBe('Nobody is told when an IT request is blocked.')
    expect(lines[1].strong).toBe(false)
    expect(lines[1].companies).toEqual([
      { id: 'snowball', name: 'Snowball', detail: 'IT and HR' },
      { id: 'hut4', name: 'Hut4', detail: 'HR' },
    ])
  })
})
