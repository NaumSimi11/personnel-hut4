import { describe, expect, it } from 'vitest'
import { buddyLine, buddyOptionLabel } from './buddy'

describe('the buddy (24 Nov, audit C3)', () => {
  it('says who the buddy is, or that none is picked yet', () => {
    expect(buddyLine('Marija Petrova')).toBe('Buddy: Marija Petrova. They were told in PeopleOS.')
    expect(buddyLine(null)).toBe('No buddy picked yet.')
  })

  it('labels each colleague with their job title when there is one', () => {
    expect(buddyOptionLabel({ id: '1', full_name: 'Ana', job_title: 'Designer' })).toBe('Ana · Designer')
    expect(buddyOptionLabel({ id: '1', full_name: 'Ana', job_title: null })).toBe('Ana')
  })
})
