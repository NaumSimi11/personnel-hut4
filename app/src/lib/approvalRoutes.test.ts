import { describe, expect, it } from 'vitest'
import { moveStep, routeRows, ROUTE_KINDS, DEFAULT_ROUTE } from './approvalRoutes'

describe('approval routes', () => {
  it('numbers the steps in order and keeps person or group', () => {
    const r = routeRows('A', 'request', [
      { label: ' HR ', approverId: '', capability: 'offer.approve' },
      { label: 'Director', approverId: 'p1', capability: 'jobs.approve' },
    ])
    expect(r.error).toBeNull()
    expect(r.rows).toEqual([
      { company_id: 'A', kind: 'request', position: 1, label: 'HR', approver_id: null, capability: 'offer.approve' },
      { company_id: 'A', kind: 'request', position: 2, label: 'Director', approver_id: 'p1', capability: null },
    ])
  })
  it('refuses an unnamed step or one with nobody', () => {
    expect(routeRows('A', 'request', [{ label: '', approverId: 'p', capability: '' }]).error).toMatch(/Name step 1/)
    expect(routeRows('A', 'request', [{ label: 'X', approverId: '', capability: '' }]).error).toMatch(/person or a group/)
  })
  it('moves a step without falling off the ends', () => {
    const s = [{ label: 'a', approverId: '', capability: 'x' }, { label: 'b', approverId: '', capability: 'x' }]
    expect(moveStep(s, 1, -1).map((x) => x.label)).toEqual(['b', 'a'])
    expect(moveStep(s, 0, -1).map((x) => x.label)).toEqual(['a', 'b'])
  })
})

describe('route kinds (decision D4: no salary band check on offers)', () => {
  it('offers one offer route, HR by default, and no outside-the-band route', () => {
    expect(ROUTE_KINDS.map((k) => k.value)).toEqual(['request', 'offer_in_band'])
    expect(ROUTE_KINDS.find((k) => k.value === 'offer_in_band')?.label).toBe('Offers')
    expect(DEFAULT_ROUTE.offer_in_band).toBe('1. HR (anyone who approves offers)')
  })
})
