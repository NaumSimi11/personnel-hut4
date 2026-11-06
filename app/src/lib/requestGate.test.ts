import { describe, expect, it } from 'vitest'
import { createRequestGate } from './requestGate'

describe('createRequestGate', () => {
  it('the latest ticket is current, older ones are not', () => {
    const gate = createRequestGate()
    const first = gate.next()
    expect(gate.isCurrent(first)).toBe(true)
    const second = gate.next()
    expect(gate.isCurrent(first)).toBe(false)
    expect(gate.isCurrent(second)).toBe(true)
  })
  it('a snapshot is dropped when a new load starts, and does not retire the load before it', () => {
    const gate = createRequestGate()
    const load = gate.next()
    const more = gate.snapshot()
    expect(gate.isCurrent(load)).toBe(true)
    gate.next()
    expect(gate.isCurrent(more)).toBe(false)
  })
  it('invalidate() retires every outstanding ticket', () => {
    const gate = createRequestGate()
    const t = gate.next()
    gate.invalidate()
    expect(gate.isCurrent(t)).toBe(false)
  })
})
