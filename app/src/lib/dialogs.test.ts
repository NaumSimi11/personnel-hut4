import { describe, expect, it } from 'vitest'
import { createDialogQueue, validateReason, type ReasonRequest } from './dialogs'

const reason: ReasonRequest = { kind: 'reason', title: 'Why?' }

describe('dialog queue', () => {
  it('asks one question at a time and settles it', async () => {
    const q = createDialogQueue()
    const p = q.ask<string | null>(reason)
    expect(q.current()?.request).toBe(reason)
    q.settle('typo')
    await expect(p).resolves.toBe('typo')
    expect(q.current()).toBeNull()
  })

  it('queues a second question until the first is settled', async () => {
    const q = createDialogQueue()
    const first = q.ask<boolean>({ kind: 'confirm', title: 'Archive?' })
    const second = q.ask<string | null>(reason)
    expect(q.current()?.request.title).toBe('Archive?')
    q.settle(true)
    await expect(first).resolves.toBe(true)
    expect(q.current()?.request.title).toBe('Why?')
    q.settle(null)
    await expect(second).resolves.toBeNull()
  })

  it('tells a listener whenever the current question changes', () => {
    const q = createDialogQueue()
    const seen: (string | null)[] = []
    q.subscribe((p) => seen.push(p?.request.title ?? null))
    q.ask(reason)
    q.settle(null)
    expect(seen).toEqual(['Why?', null])
  })

  it('ignores a settle with nothing open', () => {
    const q = createDialogQueue()
    expect(() => q.settle('x')).not.toThrow()
  })
})

describe('validateReason', () => {
  it('requires a reason by default and says so', () => {
    expect(validateReason(reason, '   ', null)).toMatch(/reason/i)
    expect(validateReason(reason, 'because', null)).toBeNull()
  })

  it('accepts an empty reason when the question says it is optional', () => {
    expect(validateReason({ ...reason, required: false }, '', null)).toBeNull()
  })

  it('requires the number when one is asked for and keeps it above the floor', () => {
    const withValue: ReasonRequest = { ...reason, value: { label: 'Days', min: 0 } }
    expect(validateReason(withValue, 'ok', null)).toMatch(/Days/)
    expect(validateReason(withValue, 'ok', -1)).toMatch(/below 0/)
    expect(validateReason(withValue, 'ok', 0)).toBeNull()
    expect(validateReason({ ...reason, value: { label: 'Days' } }, 'ok', -5)).toBeNull()
  })

  it('settles a closed dialog as cancelled so the queue never wedges', async () => {
    const q = createDialogQueue()
    const p = q.ask<string | null>(reason)
    q.settle(null)
    await expect(p).resolves.toBeNull()
    expect(q.current()).toBeNull()
  })
})
