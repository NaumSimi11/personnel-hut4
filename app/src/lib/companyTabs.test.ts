import { describe, expect, it } from 'vitest'
import { DEFERRED_TABS, type TabContext, visibleCompanyTabs } from './companyTabs'

const ALL = [
  'overview', 'people', 'structure', 'access', 'hiring', 'documents', 'equipment',
  'payroll', 'leave', 'projects', 'integrations', 'activity', 'settings',
].map((id) => ({ id, label: id }))

function ctx(over: Partial<TabContext> = {}): TabContext {
  return { isAdmin: false, can: () => false, companyKind: 'company', ...over }
}
const idsFor = (c: TabContext): string[] => visibleCompanyTabs(ALL, c).map((t) => t.id)

describe('visibleCompanyTabs', () => {
  it('hides the tabs deferred in task.md wherever the viewer stands', () => {
    expect(DEFERRED_TABS).toEqual(['equipment', 'projects'])
    const admin = idsFor(ctx({ isAdmin: true, can: () => true }))
    for (const id of DEFERRED_TABS) expect(admin).not.toContain(id)
  })

  it('keeps Structure on the holding only', () => {
    expect(idsFor(ctx({ companyKind: 'holding' }))).toContain('structure')
    expect(idsFor(ctx({ companyKind: 'company' }))).not.toContain('structure')
  })

  it('keeps Structure off a subsidiary even for an admin', () => {
    expect(idsFor(ctx({ isAdmin: true, can: () => true }))).not.toContain('structure')
  })

  it('offers Payroll only to a payroll.summary holder', () => {
    expect(idsFor(ctx())).not.toContain('payroll')
    expect(idsFor(ctx({ can: (c) => c === 'payroll.summary' }))).toContain('payroll')
  })

  it('offers Settings to admins, and to the capabilities that shape it', () => {
    expect(idsFor(ctx({ isAdmin: true }))).toContain('settings')
    expect(idsFor(ctx({ can: (c) => c === 'it.assign' }))).toContain('settings')
    expect(idsFor(ctx())).not.toContain('settings')
  })

  it('offers Activity to any of the three readers', () => {
    expect(idsFor(ctx({ can: (c) => c === 'jobs.view' }))).toContain('activity')
    expect(idsFor(ctx())).not.toContain('activity')
  })

  it('leaves the always-on tabs alone', () => {
    expect(idsFor(ctx())).toEqual(['overview', 'people', 'access', 'hiring', 'documents', 'leave', 'integrations'])
  })
})
