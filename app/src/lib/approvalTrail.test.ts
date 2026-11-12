import { describe, expect, it } from 'vitest'
import { latestRoundSteps, stepLine, type TrailRow } from './approvalTrail'

const row = (p: Partial<TrailRow>): TrailRow => ({
  subject_id: 'r1', round: 1, position: 1, label: 'HR', status: 'open', comment: null, acted_at: null, approver: null, actor: null, ...p,
})

describe('approval trail', () => {
  it('shows the latest round, the first open step waiting and later ones next', () => {
    const steps = latestRoundSteps([
      row({ round: 1, status: 'superseded' }),
      row({ round: 2, status: 'approved', actor: { full_name: 'Rita' }, acted_at: '2026-11-12T10:00:00Z' }),
      row({ round: 2, position: 2, label: 'Finance', approver: { full_name: 'Fia' } }),
      row({ round: 2, position: 3, label: 'Director' }),
    ]).r1
    expect(steps.map(stepLine)).toEqual(['1. HR: approved · Rita', '2. Finance: waiting · Fia', '3. Director: next'])
  })

  it('a step reopened after changes shows as waiting again', () => {
    const steps = latestRoundSteps([
      row({ status: 'changes_requested', comment: 'Lower it', actor: { full_name: 'Alex' }, acted_at: '2026-11-12T10:00:00Z' }),
      row({ status: 'open' }),
    ]).r1
    expect(steps).toHaveLength(1)
    expect(steps[0].state).toBe('waiting')
  })

  it('says who asked for changes and why', () => {
    const [s] = latestRoundSteps([row({ status: 'changes_requested', comment: 'Lower it', actor: { full_name: 'Alex' } })]).r1
    expect(stepLine(s)).toBe('1. HR: asked for changes · Alex — “Lower it”')
  })
})
