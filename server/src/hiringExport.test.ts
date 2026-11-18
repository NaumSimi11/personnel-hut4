import { describe, expect, it } from 'vitest'
import {
  EXPORT_COLUMNS,
  buildHiringExport,
  exportRows,
  hiringExportFilename,
  splitName,
  type ExportApplication,
  type ExportCandidate,
  type ExportJob,
} from './hiringExport.js'

const candidates: ExportCandidate[] = [
  { id: 'c-10', full_name: 'Marko Popović', provider_ref: 'ZR_10_CAND', current_title: 'Backend developer' },
  { id: 'c-2', full_name: 'Abdul vakil Khankan', provider_ref: 'ZR_2_CAND', current_title: null },
  { id: 'c-new', full_name: 'Madonna', provider_ref: null, current_title: 'Singer' },
]

const jobs: ExportJob[] = [
  { id: 'j-100', title: 'Fullstack developer Python', zoho_id: 'ZR_100_JOB', department: 'Synami Products', company: 'Synami' },
  { id: 'j-9', title: 'Chief Marketing Officer', zoho_id: 'ZR_9_JOB', department: null, company: 'HUT 4 Capital' },
]

const applications: ExportApplication[] = [
  { candidate_id: 'c-10', job_id: 'j-100', stage_key: 'screening', sub_status_key: 'sourced' },
  { candidate_id: 'c-10', job_id: 'j-9', stage_key: 'interview', sub_status_key: 'interview_hr' },
  { candidate_id: 'c-new', job_id: 'j-9', stage_key: 'offer', sub_status_key: null },
]

const statusLabels = { sourced: 'Sourced', interview_hr: 'Interview HR' }

describe('splitName', () => {
  it('takes the last word as the surname and the rest as the name', () => {
    expect(splitName('Abdul vakil Khankan')).toEqual({ first: 'Abdul vakil', last: 'Khankan' })
    expect(splitName('  Marko   Popović ')).toEqual({ first: 'Marko', last: 'Popović' })
  })

  it('leaves the surname blank for a single word', () => {
    expect(splitName('Madonna')).toEqual({ first: 'Madonna', last: '' })
    expect(splitName('')).toEqual({ first: '', last: '' })
  })
})

describe('exportRows', () => {
  const rows = exportRows({ candidates, jobs, applications, statusLabels })

  it('writes one row per application, and one for a candidate on no job', () => {
    expect(rows).toHaveLength(4)
    expect(rows.find((r) => r[2] === 'ZR_2_CAND')).toEqual([
      'Abdul vakil', 'Khankan', 'ZR_2_CAND', '', '', '', 'Sourced', '', '', '',
    ])
  })

  it('says "sourced" for a candidate on no job, as the old Zoho file did', () => {
    const plain = exportRows({ candidates, jobs, applications, statusLabels: {} })
    expect(plain.find((r) => r[2] === 'ZR_2_CAND')?.[6]).toBe('sourced')
  })

  it('fills every column in the order HR asked for', () => {
    expect(EXPORT_COLUMNS).toEqual([
      'First name', 'Last name', 'Candidate ID', 'Job Opening ID', 'Job Opening',
      'Stage', 'Status', 'Current job title', 'Department', 'Company',
    ])
    expect(rows.find((r) => r[3] === 'ZR_100_JOB')).toEqual([
      'Marko', 'Popović', 'ZR_10_CAND', 'ZR_100_JOB', 'Fullstack developer Python',
      'Screening', 'Sourced', 'Backend developer', 'Synami Products', 'Synami',
    ])
  })

  it('leaves the department blank when the job has none, and still names the company', () => {
    const row = rows.find((r) => r[2] === 'ZR_10_CAND' && r[3] === 'ZR_9_JOB')
    expect(row?.[8]).toBe('')
    expect(row?.[9]).toBe('HUT 4 Capital')
  })

  it('falls back to our own ids and to the raw status key', () => {
    const row = rows.find((r) => r[2] === 'c-new')
    expect(row?.[5]).toBe('Offered')
    expect(row?.[6]).toBe('')
    expect(exportRows({ candidates, jobs, applications, statusLabels: {} })[2][6]).toBe('sourced')
  })

  it('sorts by the Zoho candidate number, then the job number, our own ids last', () => {
    expect(rows.map((r) => `${r[2]}/${r[3]}`)).toEqual([
      'ZR_2_CAND/',
      'ZR_10_CAND/ZR_9_JOB',
      'ZR_10_CAND/ZR_100_JOB',
      'c-new/ZR_9_JOB',
    ])
  })
})

describe('buildHiringExport', () => {
  it('returns an xlsx (a zip) with the sheet in it', () => {
    const bytes = buildHiringExport({ candidates, jobs, applications, statusLabels })
    expect(bytes.subarray(0, 2).toString()).toBe('PK')
    expect(bytes.includes(Buffer.from('xl/worksheets/sheet1.xml'))).toBe(true)
  })
})

describe('hiringExportFilename', () => {
  it('names the file by the day', () => {
    expect(hiringExportFilename('2026-11-17')).toBe('peopleos-candidates-2026-11-17.xlsx')
  })
})
