import { describe, expect, it } from 'vitest'
import {
  exportFilterInput,
  exportRequest,
  exportQueryPlan,
  isWholeList,
  likePattern,
  readFilteredExport,
  type ExportFilter,
  type ExportDb,
} from './hiringExportFilter.js'
import { hiringExportFilename } from './hiringExport.js'

// ------------------------------------------------------------ a small world

const A = '10000000-0000-0000-0000-00000000000a'
const B = '10000000-0000-0000-0000-00000000000b'

type Cand = { id: string; full_name: string; provider_ref: string | null; current_title: string | null }
type AppRow = {
  id: string
  candidate_id: string
  job_id: string
  company_id: string
  stage_key: string
  sub_status_key: string | null
  in_play: boolean
}

const CANDIDATES: Cand[] = [
  { id: 'c1', full_name: 'Ana Petrova', provider_ref: 'ZR_1_CAND', current_title: 'Clerk' },
  { id: 'c2', full_name: 'Marko Anić', provider_ref: 'ZR_2_CAND', current_title: null },
  { id: 'c3', full_name: 'Ivana Stojanova', provider_ref: null, current_title: 'Analyst' },
  { id: 'c4', full_name: 'Bojan 100% Sure', provider_ref: 'ZR_4_CAND', current_title: null },
  { id: 'c5', full_name: 'Lena_Underscore', provider_ref: 'ZR_5_CAND', current_title: null },
  { id: 'c6', full_name: 'Petar Nojob', provider_ref: 'ZR_6_CAND', current_title: null },
]

const APPS: AppRow[] = [
  { id: 'a1', candidate_id: 'c1', job_id: 'j1', company_id: A, stage_key: 'screening', sub_status_key: 'contacted', in_play: true },
  { id: 'a2', candidate_id: 'c1', job_id: 'j3', company_id: B, stage_key: 'interview', sub_status_key: 'interview_hr', in_play: true },
  { id: 'a3', candidate_id: 'c2', job_id: 'j1', company_id: A, stage_key: 'screening', sub_status_key: 'unqualified', in_play: false },
  { id: 'a4', candidate_id: 'c2', job_id: 'j2', company_id: A, stage_key: 'offer', sub_status_key: 'offer_made', in_play: true },
  { id: 'a5', candidate_id: 'c3', job_id: 'j2', company_id: A, stage_key: 'hired', sub_status_key: 'hired', in_play: false },
  { id: 'a6', candidate_id: 'c3', job_id: 'j3', company_id: B, stage_key: 'screening', sub_status_key: 'contacted', in_play: true },
  { id: 'a7', candidate_id: 'c4', job_id: 'j3', company_id: B, stage_key: 'interview', sub_status_key: 'withdrawn', in_play: false },
  { id: 'a8', candidate_id: 'c5', job_id: 'j1', company_id: A, stage_key: 'screening', sub_status_key: null, in_play: true },
]

/**
 * An in-memory stand-in for the PostgREST builder: it applies eq / ilike /
 * order / range to the rows the way the database does, so the export's own
 * query decides what comes back.
 */
function fakeDb(): ExportDb & { calls: string[] } {
  const calls: string[] = []
  const embedded = () =>
    APPS.map((a) => ({ ...a, candidate: CANDIDATES.find((c) => c.id === a.candidate_id) ?? null }))
  const likeToRegex = (pattern: string) => {
    let out = ''
    for (let i = 0; i < pattern.length; i += 1) {
      const ch = pattern[i]
      if (ch === '\\') { out += pattern[i + 1].replace(/[.*+?^${}()|[\]\\]/g, '\\$&'); i += 1 }
      else if (ch === '%') out += '.*'
      else if (ch === '_') out += '.'
      else out += ch.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
    }
    return new RegExp(`^${out}$`, 'i')
  }
  return {
    calls,
    from(table: string) {
      calls.push(`from:${table}`)
      let rows: Record<string, unknown>[] = table === 'applications' ? embedded() : []
      const builder = {
        select(cols: string) { calls.push(`select:${cols.replace(/\s+/g, ' ').trim()}`); return builder },
        eq(col: string, value: unknown) { calls.push(`eq:${col}=${String(value)}`); rows = rows.filter((r) => r[col] === value); return builder },
        ilike(col: string, pattern: string) {
          calls.push(`ilike:${col}=${pattern}`)
          const [rel, field] = col.split('.')
          const re = likeToRegex(pattern)
          rows = rows.filter((r) => re.test(String((r[rel] as Record<string, unknown> | null)?.[field] ?? '')))
          return builder
        },
        order(col: string) { calls.push(`order:${col}`); rows = [...rows].sort((x, y) => String(x[col]).localeCompare(String(y[col]))); return builder },
        range(from: number, to: number) {
          return Promise.resolve({ data: rows.slice(from, to + 1), error: null })
        },
      }
      return builder
    },
  }
}

/** The answer worked out by hand from the list's rules, independent of the code under test. */
function expected(f: ExportFilter): string[] {
  const term = f.search.trim().toLowerCase()
  return APPS.filter((a) => {
    if (f.stage === 'live' && !a.in_play) return false
    if (f.stage !== 'live' && f.stage !== 'all' && a.stage_key !== f.stage) return false
    if (f.status && a.sub_status_key !== f.status) return false
    if (f.companyId && a.company_id !== f.companyId) return false
    if (term) {
      const name = CANDIDATES.find((c) => c.id === a.candidate_id)?.full_name.toLowerCase() ?? ''
      if (!name.includes(term)) return false
    }
    return true
  })
    .map((a) => `${a.candidate_id}/${a.job_id}`)
    .sort()
}

async function got(f: ExportFilter): Promise<string[]> {
  const input = await readFilteredExport(fakeDb(), f)
  return input.applications.map((a) => `${a.candidate_id}/${a.job_id}`).sort()
}

const NONE: ExportFilter = { stage: 'all', status: '', companyId: '', search: '' }

// ------------------------------------------------------------------ input

describe('exportFilterInput (what the button may send)', () => {
  it('accepts the list filters as the page holds them', () => {
    expect(exportFilterInput.parse({ stage: 'live', status: '', companyId: '', search: '' })).toEqual({
      stage: 'live', status: '', companyId: '', search: '',
    })
    expect(exportFilterInput.parse({ stage: 'interview', status: 'interview_hr', companyId: A, search: ' ana ' }).search).toBe(' ana ')
  })

  it('fills what is missing with "no filter"', () => {
    expect(exportFilterInput.parse({})).toEqual(NONE)
  })

  it('refuses a stage the list does not have, a company that is not an id, and a runaway search', () => {
    expect(exportFilterInput.safeParse({ stage: 'shortlisted' }).success).toBe(false)
    expect(exportFilterInput.safeParse({ stage: 'not_responding' }).success).toBe(false)
    expect(exportFilterInput.safeParse({ companyId: "x' or 1=1" }).success).toBe(false)
    expect(exportFilterInput.safeParse({ search: 'a'.repeat(201) }).success).toBe(false)
    expect(exportFilterInput.safeParse({ status: 'bad key!' }).success).toBe(false)
  })
})

describe('isWholeList', () => {
  it('is true only with no filter at all', () => {
    expect(isWholeList(NONE)).toBe(true)
    expect(isWholeList({ ...NONE, search: '   ' })).toBe(true)
    expect(isWholeList({ ...NONE, stage: 'live' })).toBe(false)
    expect(isWholeList({ ...NONE, status: 'contacted' })).toBe(false)
    expect(isWholeList({ ...NONE, companyId: A })).toBe(false)
    expect(isWholeList({ ...NONE, search: 'ana' })).toBe(false)
  })
})

describe('likePattern (the list\'s name search)', () => {
  it('matches anywhere and escapes the wildcards a name may hold', () => {
    expect(likePattern(' ana ')).toBe('%ana%')
    expect(likePattern('100%')).toBe('%100\\%%')
    expect(likePattern('a_b')).toBe('%a\\_b%')
  })
})

// --------------------------------------------------------- each filter alone

describe('exportQueryPlan: each filter on its own', () => {
  it('In progress keeps the applications still in play', () => {
    expect(exportQueryPlan({ ...NONE, stage: 'live' })).toEqual({ eq: [['in_play', true]], nameLike: null })
  })
  it('All stages filters nothing', () => {
    expect(exportQueryPlan(NONE)).toEqual({ eq: [], nameLike: null })
  })
  it('a stage filters by stage', () => {
    expect(exportQueryPlan({ ...NONE, stage: 'offer' }).eq).toEqual([['stage_key', 'offer']])
  })
  it('a status filters by status', () => {
    expect(exportQueryPlan({ ...NONE, status: 'contacted' }).eq).toEqual([['sub_status_key', 'contacted']])
  })
  it('a company filters by company', () => {
    expect(exportQueryPlan({ ...NONE, companyId: B }).eq).toEqual([['company_id', B]])
  })
  it('a name searches the candidate name, trimmed', () => {
    expect(exportQueryPlan({ ...NONE, search: '  ana ' }).nameLike).toBe('ana')
  })
})

describe('readFilteredExport: each filter on its own, against the rows', () => {
  it('In progress', async () => expect(await got({ ...NONE, stage: 'live' })).toEqual(expected({ ...NONE, stage: 'live' })))
  it('All stages is every application', async () => expect(await got(NONE)).toHaveLength(APPS.length))
  for (const stage of ['screening', 'interview', 'offer', 'hired']) {
    it(`stage ${stage}`, async () => expect(await got({ ...NONE, stage })).toEqual(expected({ ...NONE, stage })))
  }
  it('a status', async () => expect(await got({ ...NONE, status: 'contacted' })).toEqual(['c1/j1', 'c3/j3']))
  it('a company', async () => expect(await got({ ...NONE, companyId: B })).toEqual(['c1/j3', 'c3/j3', 'c4/j3']))
  it('a name, any case, anywhere in it', async () => {
    expect(await got({ ...NONE, search: 'ANA' })).toEqual(['c1/j1', 'c1/j3', 'c3/j2', 'c3/j3'])
  })
  it('a name with a % or _ is matched literally', async () => {
    expect(await got({ ...NONE, search: '100%' })).toEqual(['c4/j3'])
    expect(await got({ ...NONE, search: 'n_v' })).toEqual([]) // as a wildcard it would match "Stojanova"
    expect(await got({ ...NONE, search: 'a_u' })).toEqual(['c5/j1'])
    expect(await got({ ...NONE, search: 'Lena_' })).toEqual(['c5/j1'])
  })
  it('a filter nothing matches gives an empty export, not an error', async () => {
    expect(await got({ ...NONE, search: 'nobody at all' })).toEqual([])
  })
})

// ----------------------------------------------------------- combinations

describe('readFilteredExport: every combination of the four filters', () => {
  const stages = ['live', 'all', 'screening', 'interview', 'offer', 'hired']
  const statuses = ['', 'contacted', 'interview_hr', 'unqualified', 'withdrawn', 'offer_made', 'hired']
  const companies = ['', A, B]
  const searches = ['', 'ana', 'ANIĆ', 'petrova', 'zzz', '100%']
  const all: ExportFilter[] = stages.flatMap((stage) =>
    statuses.flatMap((status) => companies.flatMap((companyId) => searches.map((search) => ({ stage, status, companyId, search })))),
  )

  it(`checks all ${stages.length * statuses.length * companies.length * searches.length} combinations against the list's rules`, async () => {
    const wrong: string[] = []
    for (const f of all) {
      const [g, e] = [await got(f), expected(f)]
      if (JSON.stringify(g) !== JSON.stringify(e)) wrong.push(`${JSON.stringify(f)} → got ${g.join(',')} expected ${e.join(',')}`)
    }
    expect(wrong).toEqual([])
  })

  it('stage and status together narrow, they do not widen', async () => {
    expect(await got({ ...NONE, stage: 'screening', status: 'contacted' })).toEqual(['c1/j1', 'c3/j3'])
    expect(await got({ ...NONE, stage: 'interview', status: 'contacted' })).toEqual([])
  })

  it('company, stage, status and name all at once', async () => {
    expect(await got({ stage: 'live', status: 'contacted', companyId: A, search: 'ana' })).toEqual(['c1/j1'])
    expect(await got({ stage: 'live', status: 'contacted', companyId: B, search: 'ana' })).toEqual(['c3/j3'])
    expect(await got({ stage: 'live', status: 'contacted', companyId: B, search: 'petrova' })).toEqual([])
  })
})

// ------------------------------------------------------------ what comes back

describe('readFilteredExport: the rows it hands to the workbook', () => {
  it('sends every filter to the database, not filtered afterwards', async () => {
    const db = fakeDb()
    await readFilteredExport(db, { stage: 'interview', status: 'interview_hr', companyId: B, search: 'ana' })
    expect(db.calls).toEqual(
      expect.arrayContaining(['eq:stage_key=interview', 'eq:sub_status_key=interview_hr', `eq:company_id=${B}`, 'ilike:candidate.full_name=%ana%']),
    )
  })

  it('carries each matching candidate once, and only those with a matching application', async () => {
    const input = await readFilteredExport(fakeDb(), { ...NONE, search: 'ana' })
    expect(input.candidates.map((c) => c.id).sort()).toEqual(['c1', 'c3'])
    expect(input.candidates.find((c) => c.id === 'c6')).toBeUndefined()
  })

  it('keeps the candidate fields the sheet needs', async () => {
    const input = await readFilteredExport(fakeDb(), { ...NONE, search: 'stojanova' })
    expect(input.candidates).toEqual([{ id: 'c3', full_name: 'Ivana Stojanova', provider_ref: null, current_title: 'Analyst' }])
    expect(input.applications.map((a) => a.stage_key).sort()).toEqual(['hired', 'screening'])
  })
})

// ---------------------------------------------------------------- the request

describe('exportRequest (what the route takes from the body)', () => {
  it('with filters: exports what the list shows', () => {
    expect(exportRequest({ today: '2026-11-20', filter: { stage: 'live', status: 'contacted', companyId: A, search: 'ana' } })).toEqual({
      ok: true, today: '2026-11-20', scope: 'filtered', filter: { stage: 'live', status: 'contacted', companyId: A, search: 'ana' },
    })
  })

  it('"Export everyone", or no filter sent at all, is the whole file as before', () => {
    expect(exportRequest({ today: '2026-11-20', scope: 'everyone', filter: { stage: 'live' } })).toMatchObject({ ok: true, scope: 'everyone' })
    expect(exportRequest({ today: '2026-11-20' })).toMatchObject({ ok: true, scope: 'everyone' })
  })

  it('a filter that is not one the list can send is refused, not ignored', () => {
    expect(exportRequest({ today: '2026-11-20', filter: { stage: 'shortlisted' } })).toEqual({ ok: false, error: 'Those filters cannot be exported. Reload the page and try again.' })
    expect(exportRequest({ today: '2026-11-20', filter: 'live' })).toMatchObject({ ok: false })
  })

  it('a missing or odd date falls back to today', () => {
    const r = exportRequest({ today: 'yesterday' })
    expect(r.ok && /^\d{4}-\d{2}-\d{2}$/.test(r.today)).toBe(true)
  })
})

describe('hiringExportFilename', () => {
  it('says when the file is filtered', () => {
    expect(hiringExportFilename('2026-11-20')).toBe('peopleos-candidates-2026-11-20.xlsx')
    expect(hiringExportFilename('2026-11-20', true)).toBe('peopleos-candidates-filtered-2026-11-20.xlsx')
  })
})

// ------------------------------------------- the same rules as the list itself

describe('the export filters exactly as the Applicants list does', () => {
  it('builds the same query parts as the list for every combination', async () => {
    const { applicantsQueryPlan } = await import('../../app/src/lib/applicationQueries.js')
    const { likePattern: listLike } = await import('../../app/src/lib/likePattern.js')
    const differ: string[] = []
    for (const stage of ['live', 'all', 'screening', 'interview', 'offer', 'hired']) {
      for (const status of ['', 'contacted', 'offer_made']) {
        for (const companyId of ['', A]) {
          for (const search of ['', ' ana ', '100%', 'a_b']) {
            const f = { stage, status, companyId, search }
            const list = applicantsQueryPlan(f)
            const mine = exportQueryPlan(f)
            if (JSON.stringify(list) !== JSON.stringify(mine)) differ.push(`${JSON.stringify(f)}: list ${JSON.stringify(list)} export ${JSON.stringify(mine)}`)
            if (search && listLike(search) !== likePattern(search)) differ.push(`name ${search}`)
          }
        }
      }
    }
    expect(differ).toEqual([])
  })
})
