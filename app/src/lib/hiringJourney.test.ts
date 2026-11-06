import { describe, expect, it } from 'vitest'
import { candidateNextStep, candidateQueue } from './hiringJourney'

describe('hiring journey', () => {
  it('prioritises due work and excludes closed applications without changing the source', () => {
    const rows = [
      { stage_key: 'screening', in_play: true, next_action_due: null, owner: null },
      { stage_key: 'hired', in_play: false, next_action_due: '2026-01-01', owner: null },
      { stage_key: 'interview', in_play: true, next_action_due: '2026-10-01', owner: { full_name: 'Manager' } },
      { stage_key: 'interview', in_play: false, next_action_due: '2026-02-01', owner: null },
      { stage_key: 'offer', in_play: true, next_action_due: '2026-09-01', owner: null },
    ]
    expect(candidateQueue(rows).map(r => r.stage_key)).toEqual(['offer', 'interview', 'screening'])
    expect(rows[0]?.stage_key).toBe('screening')
  })

  it('routes offers to review and closed applications to their outcome', () => {
    expect(candidateNextStep('offer').target).toBe('candidate-offer')
    expect(candidateNextStep('interview').target).toBe('candidate-interviews')
    expect(candidateNextStep('interview', false).target).toBe('candidate-decision')
    expect(candidateNextStep('screening', false).label).toBe('View decision')
    expect(candidateNextStep('hired').target).toBe('candidate-decision')
  })
})
