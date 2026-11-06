import { beforeEach, describe, expect, it, vi } from 'vitest'
import { createPinia, setActivePinia } from 'pinia'

const from = vi.hoisted(() => vi.fn())
vi.mock('@/lib/supabase', () => ({ supabase: { from } }))

import { useHiringLookupsStore } from './hiringLookups'

function table(rows: unknown[]) {
  const q: Record<string, unknown> = {}
  q.select = () => q
  q.order = () => q
  q.then = (resolve: (v: unknown) => unknown) => resolve({ data: rows, error: null })
  return q
}

beforeEach(() => {
  setActivePinia(createPinia())
  from.mockReset()
  from.mockImplementation((name: string) =>
    table(name === 'application_stages' ? [{ key: 'new', label: 'New', sort_order: 1, is_terminal: false }] : [{ key: 'x', label: 'X', sort_order: 1 }]),
  )
})

describe('hiring lookups store', () => {
  it('two concurrent ensure() calls make one request per table', async () => {
    const store = useHiringLookupsStore()
    await Promise.all([store.ensure(), store.ensure()])
    const names = from.mock.calls.map((c) => c[0])
    expect(names.filter((n) => n === 'application_stages')).toHaveLength(1)
    expect(names.filter((n) => n === 'application_sub_statuses')).toHaveLength(1)
    expect(names.filter((n) => n === 'candidate_sources')).toHaveLength(1)
    expect(store.stages).toHaveLength(1)
  })

  it('a later ensure() reads nothing; refresh() reads again', async () => {
    const store = useHiringLookupsStore()
    await store.ensure()
    await store.ensure()
    expect(from).toHaveBeenCalledTimes(3)
    await store.refresh()
    expect(from).toHaveBeenCalledTimes(6)
  })
})
