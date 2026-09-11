import { describe, expect, it } from 'vitest'
import { diffSets, withDependencies, withoutDependents, type DependencyMap } from './permissions'

// Mirrors the seeded capability_dependencies rows this logic must honor.
const deps: DependencyMap = {
  'salary.propose': ['salary.view'],
  'salary.approve': ['salary.view'],
  'personal.view': ['people.view'],
  'jobs.approve': ['jobs.view'],
  'payroll.export': ['payroll.individual'],
}

describe('withDependencies', () => {
  it('adds the capability and its prerequisites', () => {
    const next = withDependencies(new Set(), 'salary.propose', deps)
    expect([...next].sort()).toEqual(['salary.propose', 'salary.view'])
  })

  it('does not mutate the input set', () => {
    const input = new Set<string>()
    withDependencies(input, 'jobs.approve', deps)
    expect(input.size).toBe(0)
  })
})

describe('withoutDependents', () => {
  it('removing a prerequisite cascades to everything depending on it', () => {
    const selected = new Set(['salary.view', 'salary.propose', 'salary.approve', 'people.view'])
    const next = withoutDependents(selected, 'salary.view', deps)
    expect([...next]).toEqual(['people.view'])
  })

  it('removing a leaf keeps its prerequisites', () => {
    const selected = new Set(['salary.view', 'salary.propose'])
    const next = withoutDependents(selected, 'salary.propose', deps)
    expect([...next]).toEqual(['salary.view'])
  })
})

describe('diffSets', () => {
  it('reports added and removed keys', () => {
    const { added, removed } = diffSets(new Set(['a', 'b']), new Set(['b', 'c']))
    expect(added).toEqual(['c'])
    expect(removed).toEqual(['a'])
  })
})
