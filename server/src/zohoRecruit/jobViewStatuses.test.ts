import fs from 'node:fs'
import path from 'node:path'
import { describe, expect, it } from 'vitest'
import { HR_STATUS_KEYS, hrStatusKey } from './jobViewStatuses.js'

const MIGRATION = path.resolve(__dirname, '../../../supabase/migrations/0098_hr_statuses.sql')

function seededKeys(): string[] {
  const sql = fs.readFileSync(MIGRATION, 'utf8')
  const block = sql.split('insert into hr_statuses values')[1].split(';')[0]
  return [...block.matchAll(/\('([a-z_]+)',/g)].map((m) => m[1])
}

describe('HR_STATUS_KEYS', () => {
  it('is exactly the eighteen statuses 0098 seeds', () => {
    const seeded = seededKeys()
    expect(seeded).toHaveLength(18)
    expect(new Set(seeded)).toEqual(new Set(HR_STATUS_KEYS))
  })
})

describe('hrStatusKey', () => {
  it('reads every spelling HR used in column T as its key', () => {
    expect(hrStatusKey('Contacted')).toBe('contacted')
    expect(hrStatusKey('Sourced')).toBe('sourced')
    expect(hrStatusKey('Interview HR')).toBe('interview_hr')
    expect(hrStatusKey('Interview  Stakeholders')).toBe('interview_stakeholders')
    expect(hrStatusKey('contact in future')).toBe('contact_in_future')
    expect(hrStatusKey('withdrawn ')).toBe('withdrawn')
  })

  it('is null for a blank cell or a word that is not a status', () => {
    expect(hrStatusKey('')).toBeNull()
    expect(hrStatusKey('Associated')).toBeNull()
  })
})
