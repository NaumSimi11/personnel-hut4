import { describe, expect, it } from 'vitest'
import { matchMembers, parseCompanyMapping, resolveCompany, toProjectRow } from './mapping.js'

describe('parseCompanyMapping', () => {
  it('reads project_ids and name_prefix from config', () => {
    expect(
      parseCompanyMapping({
        company_id: 'company-1',
        config: { project_ids: ['1', 2, '3'], name_prefix: 'SNW-' },
      }),
    ).toEqual({ companyId: 'company-1', projectIds: ['1', '2', '3'], namePrefix: 'SNW-' })
  })

  it('tolerates missing config -> empty project ids, null prefix', () => {
    expect(parseCompanyMapping({ company_id: 'company-1', config: {} })).toEqual({
      companyId: 'company-1',
      projectIds: [],
      namePrefix: null,
    })
  })

  it('tolerates garbage config (wrong shapes, null, arrays) without crashing', () => {
    expect(parseCompanyMapping({ company_id: 'company-1', config: null })).toEqual({
      companyId: 'company-1',
      projectIds: [],
      namePrefix: null,
    })
    expect(
      parseCompanyMapping({ company_id: 'company-1', config: { project_ids: 'not-an-array', name_prefix: 42 } }),
    ).toEqual({ companyId: 'company-1', projectIds: [], namePrefix: null })
    expect(parseCompanyMapping({ company_id: 'company-1', config: ['garbage'] })).toEqual({
      companyId: 'company-1',
      projectIds: [],
      namePrefix: null,
    })
    expect(
      parseCompanyMapping({ company_id: 'company-1', config: { project_ids: [null, {}, '1'] } }),
    ).toEqual({ companyId: 'company-1', projectIds: ['1'], namePrefix: null })
  })
})

describe('resolveCompany', () => {
  const byId = { companyId: 'by-id', projectIds: ['123'], namePrefix: null }
  const byPrefix = { companyId: 'by-prefix', projectIds: [], namePrefix: 'SNW-' }
  const alsoByPrefix = { companyId: 'also-by-prefix', projectIds: [], namePrefix: 'SNW-' }

  it('an explicit id match wins over a prefix match', () => {
    const idAndPrefix = { companyId: 'id-and-prefix', projectIds: ['123'], namePrefix: 'SNW-' }
    expect(resolveCompany({ id: '123', name: 'SNW-Website' }, [byPrefix, idAndPrefix])).toBe('id-and-prefix')
  })

  it('a prefix match resolves the company when no id matches', () => {
    expect(resolveCompany({ id: '999', name: 'SNW-Website' }, [byId, byPrefix])).toBe('by-prefix')
  })

  it('no match at all -> null (routing exception)', () => {
    expect(resolveCompany({ id: '999', name: 'Unrelated project' }, [byId, byPrefix])).toBeNull()
  })

  it('an ambiguous prefix match (two mappings match) -> null, never a guess', () => {
    expect(resolveCompany({ id: '999', name: 'SNW-Website' }, [byPrefix, alsoByPrefix])).toBeNull()
  })
})

describe('toProjectRow', () => {
  it('produces exactly the external_projects columns', () => {
    expect(
      toProjectRow(
        { id: '123', name: 'Website relaunch', status: 'Active', url: 'https://example.com', raw: { id: '123' } },
        'company-1',
        '2026-01-01T00:00:00.000Z',
      ),
    ).toEqual({
      provider_key: 'zoho_projects',
      external_id: '123',
      company_id: 'company-1',
      name: 'Website relaunch',
      status: 'Active',
      url: 'https://example.com',
      raw: { id: '123' },
      last_synced_at: '2026-01-01T00:00:00.000Z',
    })
  })

  it('defaults status/url to null and raw to {} when absent', () => {
    expect(
      toProjectRow({ id: '123', name: 'Website relaunch', raw: undefined }, 'company-1', '2026-01-01T00:00:00.000Z'),
    ).toEqual({
      provider_key: 'zoho_projects',
      external_id: '123',
      company_id: 'company-1',
      name: 'Website relaunch',
      status: null,
      url: null,
      raw: {},
      last_synced_at: '2026-01-01T00:00:00.000Z',
    })
  })
})

describe('matchMembers', () => {
  const peopleByEmail = new Map([['e2e-zoho-member@synami.com', 'person-1']])

  it('matches member emails case-insensitively and trimmed', () => {
    const { matched, unmatchedEmails } = matchMembers(
      [{ email: '  E2E-Zoho-Member@Synami.com  ', role: 'Developer', externalRef: 'u-1' }],
      peopleByEmail,
    )
    expect(matched).toEqual([{ personId: 'person-1', externalRef: 'u-1', role: 'Developer' }])
    expect(unmatchedEmails).toEqual([])
  })

  it('reports an unknown email as unmatched', () => {
    const { matched, unmatchedEmails } = matchMembers([{ email: 'unknown@synami.com' }], peopleByEmail)
    expect(matched).toEqual([])
    expect(unmatchedEmails).toEqual(['unknown@synami.com'])
  })

  it('members without an email are neither matched nor reported unmatched', () => {
    const { matched, unmatchedEmails } = matchMembers([{ email: null }], peopleByEmail)
    expect(matched).toEqual([])
    expect(unmatchedEmails).toEqual([])
  })
})
