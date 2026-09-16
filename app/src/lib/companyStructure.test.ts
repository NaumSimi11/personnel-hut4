import { describe, expect, it } from 'vitest'
import { friendlyStructureError, withOption } from './companyStructure'

describe('company structure helpers', () => {
  it('explains an RLS refusal and a duplicate in words', () => {
    expect(friendlyStructureError('new row violates row-level security policy')).toMatch(/employment\.edit/)
    expect(friendlyStructureError('duplicate key value violates unique constraint')).toMatch(/already exists/)
    expect(friendlyStructureError('other')).toBe('other')
  })

  it('places a new option in sorted order without mutating the list', () => {
    const list = [{ id: 'a', name: 'Finance' }, { id: 'c', name: 'Sales' }]
    const next = withOption(list, { id: 'b', name: 'Operations' })
    expect(next.map((o) => o.name)).toEqual(['Finance', 'Operations', 'Sales'])
    expect(list).toHaveLength(2)
  })
})
