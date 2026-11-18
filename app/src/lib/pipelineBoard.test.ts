import { describe, expect, it } from 'vitest'
import { BOARD_COLUMNS, arrange, columnsFor, dropTarget } from './pipelineBoard'

const app = (id: string, stage_key: string, sub_status_key: string | null, in_play = true) => ({ id, stage_key, sub_status_key, in_play })

describe('pipeline board', () => {
  it('puts each application in the spec column it belongs to', () => {
    const { columns, closed } = arrange(
      [
        app('a', 'screening', 'applied'),
        app('b', 'screening', 'contacted'),
        app('d', 'screening', 'contact'),
        app('e', 'interview', 'interview_task'),
        app('f', 'interview', 'interview_hr'),
        app('g', 'interview', 'interview_to_schedule'),
        app('h', 'interview', 'interview_stakeholders'),
        app('i', 'offer', 'offer_made'),
        app('j', 'hired', 'hired', false),
        app('k', 'screening', 'unqualified', false),
      ],
      [],
    )
    expect(Object.fromEntries(Object.entries(columns).map(([k, v]) => [k, v.map((x) => x.id).join('')]))).toEqual({
      applied: 'a', screening: 'bd', test: 'e', interview1: 'f', interview2: 'g', final: 'h', offer: 'i', hired: 'j',
    })
    expect(closed).toBe(1)
  })

  it('leaves out the optional stages a job skips', () => {
    expect(columnsFor(['interview_task', 'interview_stakeholders']).map((c) => c.key)).toEqual([
      'applied', 'screening', 'interview1', 'interview2', 'offer', 'hired',
    ])
    expect(BOARD_COLUMNS).toHaveLength(8)
  })

  it('a drop sets the column status; nothing lands on Hired, its own column or from a closed card', () => {
    const screening = BOARD_COLUMNS.find((c) => c.key === 'screening')!
    const hired = BOARD_COLUMNS.find((c) => c.key === 'hired')!
    expect(dropTarget(screening, app('a', 'screening', 'applied'))).toBe('sourced')
    expect(dropTarget(screening, app('b', 'screening', 'contacted'))).toBeNull()
    expect(dropTarget(hired, app('i', 'offer', 'offer_made'))).toBeNull()
    expect(dropTarget(screening, app('k', 'screening', 'unqualified', false))).toBeNull()
  })

  it('has no Shortlisted column anywhere (B2): the hiring manager reviews inside Screening', () => {
    expect(BOARD_COLUMNS.map((c) => c.key)).not.toContain('shortlisted')
    expect(BOARD_COLUMNS.map((c) => c.target)).not.toContain('shortlisted')
  })
})

describe('stage owners (B3, decision D3: three roles only)', () => {
  const ownerOf = (key: string) => BOARD_COLUMNS.find((c) => c.key === key)?.owner

  it('gives the technical test, Interview 2 and the final interview to the hiring manager', () => {
    expect(ownerOf('test')).toBe('Hiring Manager')
    expect(ownerOf('interview2')).toBe('Hiring Manager')
    expect(ownerOf('final')).toBe('Hiring Manager')
  })

  it('names only Recruiter, Hiring Manager or General Administrator as an owner', () => {
    const owners = BOARD_COLUMNS.filter((c) => c.key !== 'applied').map((c) => c.owner)
    expect(owners.every((o) => ['Recruiter', 'Hiring Manager', 'General Administrator'].includes(o))).toBe(true)
  })
})
