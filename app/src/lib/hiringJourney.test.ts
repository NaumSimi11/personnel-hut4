import { describe, expect, it } from 'vitest'
import { candidateNextStep, candidateQueue } from './hiringJourney'

describe('hiring journey', () => {
  it('prioritises due work and excludes closed applications without changing the source', () => {
    const rows = [
      { stage_key: 'new', next_action_due: null, owner: null },
      { stage_key: 'hired', next_action_due: '2026-01-01', owner: null },
      { stage_key: 'interview', next_action_due: '2026-10-01', owner: { full_name: 'Manager' } },
      { stage_key: 'rejected', next_action_due: null, owner: null },
      { stage_key: 'offer', next_action_due: '2026-09-01', owner: null },
    ]
    expect(candidateQueue(rows).map(r => r.stage_key)).toEqual(['offer', 'interview', 'new'])
    expect(rows[0]?.stage_key).toBe('new')
  })

  it('routes offers to review and closed applications to their outcome', () => {
    expect(candidateNextStep('offer').target).toBe('candidate-offer')
    expect(candidateNextStep('interview').target).toBe('candidate-interviews')
    expect(candidateNextStep('withdrawn').target).toBe('candidate-decision')
    expect(candidateNextStep('hired').target).toBe('candidate-decision')
  })
})
