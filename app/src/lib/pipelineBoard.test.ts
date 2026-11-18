import { describe, expect, it } from 'vitest'
import { BOARD_COLUMNS, arrange, columnsFor, dropTarget } from './pipelineBoard'

const app = (id: string, stage_key: string, sub_status_key: string | null, in_play = true) => ({ id, stage_key, sub_status_key, in_play })

describe('pipeline board', () => {
  it('puts each application in the spec column it belongs to', () => {
    const { columns, closed } = arrange(
      [
        app('a', 'screening', 'applied'),
        app('b', 'screening', 'contacted'),
        app('c', 'screening', 'shortlisted'),
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
      applied: 'a', screening: 'b', shortlisted: 'cd', test: 'e', interview1: 'f', interview2: 'g', final: 'h', offer: 'i', hired: 'j',
    })
    expect(closed).toBe(1)
  })

  it('leaves out the optional stages a job skips', () => {
    expect(columnsFor(['interview_task', 'interview_stakeholders']).map((c) => c.key)).toEqual([
      'applied', 'screening', 'shortlisted', 'interview1', 'interview2', 'offer', 'hired',
    ])
    expect(BOARD_COLUMNS).toHaveLength(9)
  })

  it('a drop sets the column status; nothing lands on Hired, its own column or from a closed card', () => {
    const shortlisted = BOARD_COLUMNS.find((c) => c.key === 'shortlisted')!
    const hired = BOARD_COLUMNS.find((c) => c.key === 'hired')!
    expect(dropTarget(shortlisted, app('a', 'screening', 'applied'))).toBe('shortlisted')
    expect(dropTarget(shortlisted, app('c', 'screening', 'shortlisted'))).toBeNull()
    expect(dropTarget(hired, app('i', 'offer', 'offer_made'))).toBeNull()
    expect(dropTarget(shortlisted, app('k', 'screening', 'unqualified', false))).toBeNull()
  })
})

describe('stage owners (B3, decision D3: three roles only)', () => {
  const ownerOf = (key: string) => BOARD_COLUMNS.find((c) => c.key === key)?.owner

  it('gives the technical test, Interview 2 and the final interview to the hiring manager', () => {
    expect(ownerOf('test')).toBe('Hiring manager')
    expect(ownerOf('interview2')).toBe('Hiring manager')
    expect(ownerOf('final')).toBe('Hiring manager')
  })

  it('names only Recruiter, Hiring manager or HR as an owner', () => {
    const owners = BOARD_COLUMNS.filter((c) => c.key !== 'applied').map((c) => c.owner)
    expect(owners.every((o) => ['Recruiter', 'Hiring manager', 'HR'].includes(o))).toBe(true)
  })
})
