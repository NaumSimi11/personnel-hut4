import fs from 'node:fs'
import path from 'node:path'
import { describe, expect, it } from 'vitest'
import { ZOHO_STATUS_KEY } from './jobViewStatuses.js'

const MIGRATION = path.resolve(__dirname, '../../../supabase/migrations/0095_zoho_statuses.sql')

function seededStatuses(): Array<{ key: string; label: string }> {
  const sql = fs.readFileSync(MIGRATION, 'utf8')
  const block = sql.split('insert into public.application_sub_statuses')[1].split(';')[0]
  return [...block.matchAll(/\('([a-z_]+)',\s*'[a-z]+',\s*'([^']+)'/g)].map((m) => ({ key: m[1], label: m[2] }))
}

describe('ZOHO_STATUS_KEY', () => {
  const seeded = seededStatuses()

  it('reads all 37 seeded statuses', () => {
    expect(seeded).toHaveLength(37)
  })

  it('covers exactly the seeded keys', () => {
    expect(new Set(Object.values(ZOHO_STATUS_KEY))).toEqual(new Set(seeded.map((s) => s.key)))
  })

  it('maps each seeded label to its key', () => {
    for (const { key, label } of seeded) expect(ZOHO_STATUS_KEY[label]).toBe(key)
  })

  it('also takes the lower-case spelling of Not contacted', () => {
    expect(ZOHO_STATUS_KEY['Not contacted']).toBe('not_contacted')
  })
})
