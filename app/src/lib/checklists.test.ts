import { describe, expect, it } from 'vitest'
import { OWNER_ROLES, PHASES_FOR, emptyTemplateLine, filterPlans, groupByPhase, lineInput, messageForChecklist, moved, ownerLabel, planMeta, progress, type ChecklistTask, whenLabel } from './checklists'

const t = (over: Partial<ChecklistTask>): ChecklistTask => ({
  id: 'x',
  title: 'T',
  owner_role: 'hr',
  phase_key: 'before_start',
  due_date: null,
  critical: false,
  status: 'open',
  blocked_reason: null,
  skip_reason: null,
  done_at: null,
  owner: null,
  ...over,
})

describe('checklist progress', () => {
  it('counts done and skipped as closed, and critical open lines as gaps', () => {
    const p = progress([t({ status: 'done' }), t({ status: 'skipped' }), t({ status: 'open', critical: true }), t({ status: 'blocked' })])
    expect(p).toEqual({ closed: 2, total: 4, percent: 50, criticalOpen: 1 })
  })
  it('is 0 of 0 with no lines', () => {
    expect(progress([])).toEqual({ closed: 0, total: 0, percent: 0, criticalOpen: 0 })
  })
})

describe('grouping', () => {
  it('keeps the phase order and drops empty phases', () => {
    const phases = [
      { key: 'before_start', label: 'Before start', sort_order: 10 },
      { key: 'day_one', label: 'Day one', sort_order: 20 },
      { key: 'week_one', label: 'Week one', sort_order: 30 },
    ]
    const grouped = groupByPhase(phases, [t({ id: 'a', phase_key: 'day_one' }), t({ id: 'b', phase_key: 'before_start' })])
    expect(grouped.map((g) => g.key)).toEqual(['before_start', 'day_one'])
    expect(grouped[0]?.tasks.map((x) => x.id)).toEqual(['b'])
  })
})

describe('labels', () => {
  it('names the owner and says when a line is due relative to the anchor', () => {
    expect(ownerLabel('it')).toBe('IT')
    expect(ownerLabel('employee')).toBe('The person')
    expect(whenLabel('before_start', -3, 'onboarding')).toBe('3 days before the start')
    expect(whenLabel('day_one', 0, 'onboarding')).toBe('On the first day')
    expect(whenLabel('week_one', 2, 'onboarding')).toBe('2 days after the start')
    expect(whenLabel('last_day', 0, 'offboarding')).toBe('On the last day')
    expect(whenLabel('after_departure', 1, 'offboarding')).toBe('1 day after the last day')
    expect(whenLabel('before_last_day', -10, 'offboarding')).toBe('10 days before the last day')
  })
  it('lists the phases that belong to each kind', () => {
    expect(PHASES_FOR.onboarding).toEqual(['before_start', 'day_one', 'week_one', 'month_one'])
    expect(PHASES_FOR.offboarding).toEqual(['before_last_day', 'last_day', 'after_departure'])
    expect(OWNER_ROLES.map((o) => o.key)).toContain('manager')
  })
})

describe('template lines', () => {
  it('starts a new line as an HR task before the anchor', () => {
    expect(emptyTemplateLine('onboarding')).toMatchObject({ title: '', ownerRole: 'hr', phaseKey: 'before_start', dueOffsetDays: -1, critical: false, requiresEvidence: false })
    expect(emptyTemplateLine('offboarding').phaseKey).toBe('before_last_day')
  })
  it('refuses a short title and a phase of the other kind', () => {
    const base = { ...emptyTemplateLine('onboarding'), title: 'Badge issued' }
    expect(lineInput('onboarding').safeParse(base).success).toBe(true)
    expect(lineInput('onboarding').safeParse({ ...base, title: 'B' }).success).toBe(false)
    expect(lineInput('onboarding').safeParse({ ...base, phaseKey: 'last_day' }).success).toBe(false)
    expect(lineInput('onboarding').safeParse({ ...base, dueOffsetDays: 500 }).success).toBe(false)
  })
  it('moves a line up or down and returns the new id order', () => {
    const ids = ['a', 'b', 'c']
    expect(moved(ids, 'b', -1)).toEqual(['b', 'a', 'c'])
    expect(moved(ids, 'b', 1)).toEqual(['a', 'c', 'b'])
    expect(moved(ids, 'a', -1)).toEqual(ids)
    expect(moved(ids, 'c', 1)).toEqual(ids)
  })
})

describe('queue filters', () => {
  const plans = [
    { id: '1', company_id: 'c1', plan_tasks: [t({ owner_role: 'it', status: 'open' }), t({ owner_role: 'hr', status: 'done' })] },
    { id: '2', company_id: 'c2', plan_tasks: [t({ owner_role: 'hr', status: 'open' })] },
    { id: '3', company_id: 'c1', plan_tasks: [t({ owner_role: 'it', status: 'done' })] },
  ]
  it('narrows by company and by an owner with something still open', () => {
    expect(filterPlans(plans, { companyId: '', ownerRole: '' }).map((p) => p.id)).toEqual(['1', '2', '3'])
    expect(filterPlans(plans, { companyId: 'c1', ownerRole: '' }).map((p) => p.id)).toEqual(['1', '3'])
    expect(filterPlans(plans, { companyId: '', ownerRole: 'it' }).map((p) => p.id)).toEqual(['1'])
    expect(filterPlans(plans, { companyId: 'c2', ownerRole: 'it' })).toEqual([])
  })
})

describe('messages', () => {
  it('turns the capability refusals into words', () => {
    expect(messageForChecklist({ code: '42501', message: 'Shaping a checklist needs tasks.assign in this company.' })).toMatch(/tasks\.assign/)
    expect(messageForChecklist({ code: '22023', message: 'Days must be between -60 and 120.' })).toBe('Days must be between -60 and 120.')
    expect(messageForChecklist({ message: 'new row violates row-level security policy' })).toMatch(/permission/)
  })
})

describe('planMeta', () => {
  const base = {
    companyName: 'Snowball',
    jobTitle: 'Frontend Dev',
    startDate: '2026-09-17',
    endDate: null,
    closed: 0,
    total: 11,
  }

  it('names the role, so two hires with the same name stay apart', () => {
    expect(planMeta(base, 'onboarding')).toBe('Snowball · Frontend Dev · starts 2026-09-17 · 0/11 done')
  })

  it('leaves the role out rather than printing a gap when there is none', () => {
    expect(planMeta({ ...base, jobTitle: null }, 'onboarding')).toBe('Snowball · starts 2026-09-17 · 0/11 done')
  })

  it('falls back to a dash for a company it cannot name', () => {
    expect(planMeta({ ...base, companyName: null, jobTitle: null }, 'onboarding')).toBe(
      '— · starts 2026-09-17 · 0/11 done',
    )
  })

  it('counts the closed lines', () => {
    expect(planMeta({ ...base, closed: 7, total: 11 }, 'onboarding')).toContain('7/11 done')
  })

  it('speaks of the last day when leaving', () => {
    expect(planMeta(base, 'offboarding')).toBe('Snowball · Frontend Dev · last day 2026-09-17 · 0/11 done')
  })

  it('adds the end of employment only when it differs from the last day', () => {
    expect(planMeta({ ...base, endDate: '2026-09-30' }, 'offboarding')).toContain('employment ends 2026-09-30')
    expect(planMeta({ ...base, endDate: '2026-09-17' }, 'offboarding')).not.toContain('employment ends')
  })
})
