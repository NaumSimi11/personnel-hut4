import { describe, expect, it } from 'vitest'
import { planSections } from './planSections'

const full = {
  kind: 'onboarding' as const,
  hasPerson: true,
  canViewTasks: true,
  canViewIt: true,
}
const ids = (o: Parameters<typeof planSections>[0]) => planSections(o).map((s) => s.id)

describe('planSections', () => {
  it('lists every section of a fully visible onboarding plan, in page order', () => {
    expect(ids(full)).toEqual(['checklist', 'welcome', 'kit', 'access', 'handover'])
  })

  it('always keeps the checklist, whatever else is hidden', () => {
    expect(ids({ kind: 'onboarding', hasPerson: false, canViewTasks: false, canViewIt: false })).toEqual([
      'checklist',
    ])
  })

  it('drops the welcome note and starter kit when someone is leaving, and keeps the access list', () => {
    expect(ids({ ...full, kind: 'offboarding' })).toEqual(['checklist', 'access', 'handover'])
  })

  it('hides the access list from a viewer who could not open this page anyway', () => {
    expect(ids({ kind: 'offboarding', hasPerson: true, canViewTasks: false, canViewIt: false })).toEqual(['checklist'])
  })

  it('hides the welcome note and handover without the tasks capability', () => {
    expect(ids({ ...full, canViewTasks: false })).toEqual(['checklist', 'kit'])
  })

  it('hides the starter kit without the IT capability', () => {
    expect(ids({ ...full, canViewIt: false })).toEqual(['checklist', 'welcome', 'access', 'handover'])
  })

  it('hides what needs a person when the plan has none', () => {
    expect(ids({ ...full, hasPerson: false })).toEqual(['checklist', 'welcome'])
  })

  it('names the access section for the question being asked', () => {
    expect(planSections({ ...full, kind: 'offboarding' }).find((s) => s.id === 'access')?.label).toBe(
      'Access to shut down',
    )
  })

  it('gives every section a label to show in the nav', () => {
    expect(planSections(full)).toEqual([
      { id: 'checklist', label: 'Checklist' },
      { id: 'welcome', label: 'Welcome note' },
      { id: 'kit', label: 'Starter kit' },
      { id: 'access', label: 'Access' },
      { id: 'handover', label: 'Handover' },
    ])
  })
})
