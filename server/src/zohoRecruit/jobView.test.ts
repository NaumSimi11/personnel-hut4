import path from 'node:path'
import { describe, expect, it } from 'vitest'
import { parseCsv, readCsv, type CsvRow } from './csv.js'
import { buildJobViewPayload, splitNotesLog } from './jobView.js'
import { SOURCE_TO_KEY, mapSource } from './mapping.js'

const TZ = 'Europe/Skopje'
const FIXTURE = path.resolve(__dirname, 'fixtures/job-view.csv')
const rows = (): CsvRow[] => readCsv(FIXTURE)

describe('buildJobViewPayload on the fixture', () => {
  const { payload, counts, problems } = buildJobViewPayload(rows(), { tz: TZ })
  const candidate = (id: string) => payload.candidates.find((c) => c.zoho_id === id)!

  it('has no problems and the expected counts', () => {
    expect(problems).toEqual([])
    expect(counts).toEqual({
      candidates: 4,
      applications: 5,
      notes: 2,
      byStatus: { interview_scheduled: 1, never_contact: 1, contact_in_future: 1, not_contacted: 1, hired: 1 },
    })
  })

  it('keeps both status columns apart and counts only the one that counts', () => {
    expect(Object.keys(rows()[0]).filter((k) => k.toLowerCase() === 'status for this job')).toHaveLength(2)
    const app = payload.applications.find((a) => a.job_display_id === 'JO-1' && a.candidate_zoho_id === '1001')!
    expect(app.sub_status_key).toBe('interview_scheduled')
    expect(app.custom.zoho['Status for this job']).toBeUndefined()
    expect(app.custom.zoho['Status for this Job']).toBe('Interview-Scheduled')
  })

  it('NEVER-contact beats Contact in Future on the same candidate', () => {
    expect(candidate('1001').contact_rule).toEqual({ rule: 'do_not_contact', reason: 'Zoho: NEVER to be contacted again' })
  })

  it('maps Not contacted to not_contacted, no rule', () => {
    const app = payload.applications.find((a) => a.candidate_zoho_id === '1002')!
    expect(app.sub_status_key).toBe('not_contacted')
    expect(candidate('1002').contact_rule).toBeNull()
  })

  it('a row without a job is a candidate only', () => {
    expect(candidate('1003').full_name).toBe('Cvetka Lazna')
    expect(payload.applications.some((a) => a.candidate_zoho_id === '1003')).toBe(false)
  })

  it('cleans the candidate fields and converts stamps to UTC', () => {
    const c = candidate('1001')
    expect(c.email).toBe('ana.primerova@example.com')
    expect(c.phone).toBe('+389 70 000 001')
    expect(c.skills).toEqual(['Python', 'SQL'])
    expect(c.source_key).toBe('head_hunt')
    expect(c.last_activity_at).toBe('2024-08-08T09:25:00.000Z')
    expect(candidate('1002').email).toBeNull()
  })

  it('received_at falls back to the last activity; status_at is the update stamp', () => {
    const jo1 = payload.applications.find((a) => a.candidate_zoho_id === '1002')!
    expect(jo1.received_at).toBe('2024-01-02T07:00:00.000Z')
    expect(jo1.status_at).toBe('2024-01-03T07:00:00.000Z')
    const hired = payload.applications.find((a) => a.candidate_zoho_id === '1004')!
    expect(hired.hired_date).toBe('2022-12-01')
  })

  it('keeps the notes of the job, newest first', () => {
    expect(payload.notes.map((n) => [n.seq, n.kind_label, n.author_name])).toEqual([
      [1, 'Call', 'Ana Testova'],
      [2, 'Email', 'Boris Probni'],
    ])
  })
})

describe('buildJobViewPayload problems', () => {
  const header = Object.keys(rows()[0])
  const csv = (...lines: string[][]) => parseCsv([header.join(','), ...lines.map((l) => l.join(','))].join('\n'))
  const line = (over: Record<string, string>) => header.map((h) => over[h] ?? '')

  it('reports an unknown status as one problem and no application', () => {
    const r = buildJobViewPayload(csv(line({ 'Candidate ID': '9', 'Full Name': 'X', 'Job Opening ID': 'JO-9', 'Status for this Job': 'Made-Up' })), { tz: TZ })
    expect(r.problems).toHaveLength(1)
    expect(r.problems[0].ref).toBe('9/JO-9')
    expect(r.payload.applications).toEqual([])
    expect(r.payload.candidates).toHaveLength(1)
  })

  it('skips a row of bare commas but reports data without a Candidate ID', () => {
    const r = buildJobViewPayload(csv(line({}), line({ 'Full Name': 'Orphan', 'Job Opening ID': 'JO-9', 'Status for this Job': 'Hired' })), { tz: TZ })
    expect(r.problems).toEqual([{ ref: 'record 3', message: 'Blank Candidate ID' }])
    expect(r.payload.candidates).toEqual([])
  })

  it('reports an unknown source', () => {
    const r = buildJobViewPayload(csv(line({ 'Candidate ID': '9', 'Full Name': 'X', Source: 'Pigeon' })), { tz: TZ })
    expect(r.problems).toHaveLength(1)
  })

  it('reports a note without a header', () => {
    const r = buildJobViewPayload(
      csv(line({ 'Candidate ID': '9', 'Full Name': 'X', 'Job Opening ID': 'JO-9', 'Status for this Job': 'Hired', 'Job Notes Log (newest first)': 'just text' })),
      { tz: TZ },
    )
    expect(r.problems).toHaveLength(1)
    expect(r.payload.notes[0]).toMatchObject({ kind_label: '', author_name: '', body: 'just text' })
  })
})

describe('splitNotesLog', () => {
  it('splits two entries on the blank line, keeping multi-line bodies', () => {
    const out = splitNotesLog('[2024-08-08 11:25] Call – Ana Testova:\nline one\nline two\n\n[2024-08-01 09:05] Email – Boris Probni:\nhi', TZ)
    expect(out).toEqual([
      { occurred_at: '2024-08-08T09:25:00.000Z', kind_label: 'Call', author_name: 'Ana Testova', body: 'line one\nline two' },
      { occurred_at: '2024-08-01T07:05:00.000Z', kind_label: 'Email', author_name: 'Boris Probni', body: 'hi' },
    ])
  })
  it('keeps a blank line inside a body', () => {
    const out = splitNotesLog('[2024-08-08 11:25] Call \u2013 Ana Testova:\npara one\n\npara two\n\n[2024-08-01 09:05] Email \u2013 Boris Probni:\nhi', TZ)
    expect(out.map((n) => n.body)).toEqual(['para one\n\npara two', 'hi'])
  })
  it('returns [] for an empty log', () => {
    expect(splitNotesLog('', TZ)).toEqual([])
  })
})

describe('sources seen in the Candidate-Job View', () => {
  it.each([
    'Head Hunt', 'Imported using Resume Extractor', 'Advertisement Linkedin', 'Added by User',
    'Advertisement External Career Pages', 'CareerSite', 'Advertisement', 'Employee Referral', 'External Referral',
  ])('maps %s', (source) => {
    expect(Object.values(SOURCE_TO_KEY)).toContain(mapSource(source))
  })
})
