import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { createPinia, setActivePinia } from 'pinia'

const from = vi.hoisted(() => vi.fn())
vi.mock('@/lib/supabase', () => ({ supabase: { from, rpc: vi.fn() } }))

import { useNotificationsStore } from './notifications'

const selects: { columns: string; opts: unknown }[] = []

// The tests run in node: a minimal document with the two things the store uses.
const fakeDocument = {
  visibilityState: 'visible' as 'visible' | 'hidden',
  listeners: new Set<() => void>(),
  addEventListener(_type: string, fn: () => void) {
    this.listeners.add(fn)
  },
  removeEventListener(_type: string, fn: () => void) {
    this.listeners.delete(fn)
  },
}

function setVisibility(state: 'visible' | 'hidden'): void {
  fakeDocument.visibilityState = state
}

beforeEach(() => {
  vi.useFakeTimers()
  vi.stubGlobal('document', fakeDocument)
  fakeDocument.listeners.clear()
  setActivePinia(createPinia())
  selects.length = 0
  from.mockReset()
  from.mockImplementation(() => {
    const q: Record<string, unknown> = {}
    q.select = (columns: string, opts: unknown) => {
      selects.push({ columns, opts })
      return q
    }
    q.is = () => q
    q.order = () => q
    q.limit = () => q
    q.then = (resolve: (v: unknown) => unknown) => resolve({ data: [], count: 3, error: null })
    return q
  })
})

afterEach(() => {
  vi.useRealTimers()
  vi.unstubAllGlobals()
})

describe('notifications bell', () => {
  it('makes no request in five minutes while the tab is hidden', async () => {
    setVisibility('hidden')
    const store = useNotificationsStore()
    store.start()
    await vi.advanceTimersByTimeAsync(5 * 60_000)
    expect(from).not.toHaveBeenCalled()
    store.stop()
  })

  it('makes five head-only count requests and no list request while visible', async () => {
    setVisibility('visible')
    const store = useNotificationsStore()
    store.start()
    await vi.advanceTimersByTimeAsync(0)
    from.mockClear()
    selects.length = 0
    await vi.advanceTimersByTimeAsync(5 * 60_000)
    expect(from).toHaveBeenCalledTimes(5)
    expect(selects.every((s) => s.columns === 'id' && JSON.stringify(s.opts) === JSON.stringify({ count: 'exact', head: true }))).toBe(true)
    expect(store.unread).toBe(3)
    store.stop()
  })

  it('counts once when the tab becomes visible again', async () => {
    setVisibility('hidden')
    const store = useNotificationsStore()
    store.start()
    setVisibility('visible')
    fakeDocument.listeners.forEach((fn) => fn())
    await vi.advanceTimersByTimeAsync(0)
    expect(from).toHaveBeenCalledTimes(1)
    store.stop()
  })
})
