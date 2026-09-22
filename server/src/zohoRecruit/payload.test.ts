import { describe, expect, it } from 'vitest'
import fs from 'node:fs'
import os from 'node:os'
import path from 'node:path'
import { spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { readExport, type CsvRow } from './csv.js'
import {
  COLUMN_MAP,
  buildPayload,
  candidateEmail,
  candidateName,
  candidatePhone,
  candidateSkills,
  contactFlags,
  educationOf,
  linkedinKey,
  nameKey,
  phoneKey,
} from './payload.js'

const FIXTURES = path.join(path.dirname(fileURLToPath(import.meta.url)), 'fixtures')
const TZ = 'Europe/Skopje'
const C1 = 'Zrecruit_10000000000000201'
const C2 = 'Zrecruit_10000000000000202'
const C3 = 'Zrecruit_10000000000000203'

function cand(over: Partial<CsvRow>): CsvRow {
  return { 'Candidate Id': 'Zrecruit_1', 'Candidate ID': 'ZR_1_CAND', 'First Name': '', 'Last Name': '', 'Full Name': '', Email: '', Phone: '', Mobile: '', 'Secondary Email': '', ...over }
}

describe('the key mirrors', () => {
  it('phoneKey: the MK forms of one number share a key', () => {
    for (const form of ['+389 70 123 456', '070 123 456', '070123456', '00389 70 123 456', '+38970123456', '070-123-456']) {
      expect(phoneKey(form), form).toBe('70123456')
    }
    expect(phoneKey('1234567')).toBeNull()
    expect(phoneKey('')).toBeNull()
    expect(phoneKey(null)).toBeNull()
  })

  it('nameKey: NFD and NFC spellings are equal, order and brackets do not matter', () => {
    expect(nameKey('Möllersten Test')).toBe('mollersten test')
    expect(nameKey('Test Möllersten')).toBe('mollersten test')
    expect(nameKey('Dimitar (Benjamin) Iliev')).toBe('dimitar iliev')
    expect(nameKey('Iliev Dimitar')).toBe('dimitar iliev')
    expect(nameKey('Łukasz Øre Đorđe')).toBe('dorde lukasz ore')
    expect(nameKey('')).toBeNull()
  })

  it('linkedinKey: the /in/ slug, lower-cased, without query or trailing slash', () => {
    expect(linkedinKey('https://www.linkedin.com/in/Test-One/')).toBe('test-one')
    expect(linkedinKey('linkedin.com/in/test-one?trk=x')).toBe('test-one')
    expect(linkedinKey('https://www.linkedin.com/search/results/')).toBeNull()
    expect(linkedinKey('')).toBeNull()
  })
})

describe('candidate fields', () => {
  it('name: Full Name, then First + Last, then Last, then the display id', () => {
    expect(candidateName(cand({ 'Full Name': ' Test One ', 'First Name': 'X', 'Last Name': 'Y' }))).toBe('Test One')
    expect(candidateName(cand({ 'First Name': 'Nom', 'Last Name': 'Deux' }))).toBe('Nom Deux')
    expect(candidateName(cand({ 'Last Name': 'Deux' }))).toBe('Deux')
    expect(candidateName(cand({}))).toBe('ZR_1_CAND')
  })

  it('email: a malformed address goes to custom.links.raw_email; the secondary is kept', () => {
    expect(candidateEmail(cand({ Email: ' Test.One@Example.test ' }))).toEqual({ email: 'test.one@example.test', links: {} })
    expect(candidateEmail(cand({ Email: 'not-an-email' }))).toEqual({ email: null, links: { raw_email: 'not-an-email' } })
    expect(candidateEmail(cand({ Email: '', 'Secondary Email': 'alt@example.test' })))
      .toEqual({ email: null, links: { secondary_email: 'alt@example.test' } })
  })

  it('phone: Mobile first, then Phone; the other one is kept in custom.links', () => {
    expect(candidatePhone(cand({ Mobile: '+389 70 123 456' }))).toEqual({ phone: '+389 70 123 456', links: {} })
    expect(candidatePhone(cand({ Phone: '070 123 456' }))).toEqual({ phone: '070 123 456', links: {} })
    expect(candidatePhone(cand({ Mobile: '070', Phone: '071' }))).toEqual({ phone: '070', links: { phone: '071' } })
    expect(candidatePhone(cand({}))).toEqual({ phone: null, links: {} })
  })

  it('skills: split on the comma and trimmed; an item over 60 characters is not a skill', () => {
    expect(candidateSkills('Vue, TypeScript ,  SQL')).toEqual({ skills: ['Vue', 'TypeScript', 'SQL'], dropped: [] })
    const long = 'x'.repeat(61)
    expect(candidateSkills(`Vue, ${long}`)).toEqual({ skills: ['Vue'], dropped: [long] })
    expect(candidateSkills('')).toEqual({ skills: [], dropped: [] })
  })

  it('education rows in file order, Mon-YYYY → YYYY-MM, the Jan-1 sentinel → null', () => {
    const rows: CsvRow[] = [
      { TABULARROWID: 'Zrecruit_1', 'Candidate Id': 'Zrecruit_9', 'Institute / School': 'Example University', 'Major / Department': 'CS', Degree: 'BSc', Duration_From: 'Sep-2014', Duration_To: 'Jun-2018', 'Currently pursuing': '' },
      { TABULARROWID: 'Zrecruit_2', 'Candidate Id': 'Zrecruit_9', 'Institute / School': 'Example College', 'Major / Department': '', Degree: '', Duration_From: 'Jan-1', Duration_To: '', 'Currently pursuing': '1' },
    ]
    expect(educationOf(rows)).toEqual([
      { institute: 'Example University', major: 'CS', degree: 'BSc', from: '2014-09', to: '2018-06', current: false, zoho_row_id: 'Zrecruit_1' },
      { institute: 'Example College', major: null, degree: null, from: null, to: null, current: true, zoho_row_id: 'Zrecruit_2' },
    ])
  })
})

describe('contactFlags', () => {
  const users = new Map([['Zrecruit_10000000000000101', 'Kristina Testova']])
  const never = (over: Partial<CsvRow>): CsvRow => ({
    'Associated Id': 'Zrecruit_5', 'Candidate Status': 'NEVER to be contacted again', 'Modified By': 'Zrecruit_10000000000000101', 'Modified Time': '2024-02-20 09:00:00.0', ...over,
  })
  const note = (over: Partial<CsvRow>): CsvRow => ({
    'Note Id': 'Zrecruit_6', 'Note Type': 'Change Status', 'Note Content': 'Asked us not to call again.', 'Created Time': '02/19/2024 04:00 PM', ...over,
  })
  const base = cand({ 'Candidate Status': 'Contacted', 'Modified By': 'Zrecruit_10000000000000101', 'Modified Time': '03/01/2024 10:00 AM' })

  it('an association-level NEVER: the flag, its time, its author and the nearby note as the reason', () => {
    expect(contactFlags({ candidate: base, associations: [never({})], notes: [note({})], users, tz: TZ })).toEqual({
      do_not_contact: true,
      do_not_contact_reason: 'Asked us not to call again.',
      do_not_contact_at: '2024-02-20T08:00:00.000Z',
      do_not_contact_by_zoho_id: 'Zrecruit_10000000000000101',
      contact_later: false,
      reason_synthesised: false,
    })
  })

  it('a note outside the 7-day window or of another type does not become the reason', () => {
    const far = note({ 'Created Time': '01/01/2024 04:00 PM' })
    const call = note({ 'Note Type': 'Call' })
    const r = contactFlags({ candidate: base, associations: [never({})], notes: [far, call], users, tz: TZ })
    expect(r.do_not_contact_reason).toBe('Zoho Recruit: NEVER to be contacted again (set by Kristina Testova on 20 Feb 2024)')
    expect(r.reason_synthesised).toBe(true)
  })

  it('the latest of several nearby notes wins and long bodies are cut at 300 characters', () => {
    const older = note({ 'Note Content': 'older', 'Created Time': '02/18/2024 04:00 PM' })
    const newer = note({ 'Note Type': 'Notes', 'Note Content': 'n'.repeat(400), 'Created Time': '02/21/2024 04:00 PM' })
    const r = contactFlags({ candidate: base, associations: [never({})], notes: [older, newer], users, tz: TZ })
    expect(r.do_not_contact_reason).toBe('n'.repeat(300))
  })

  it('a candidate-level NEVER without a NEVER association uses the candidate stamp', () => {
    const c = cand({ 'Candidate Status': 'NEVER to be contacted again', 'Modified By': 'Zrecruit_10000000000000101', 'Modified Time': '03/01/2024 10:00 AM' })
    expect(contactFlags({ candidate: c, associations: [], notes: [], users, tz: TZ })).toMatchObject({
      do_not_contact: true,
      do_not_contact_at: '2024-03-01T09:00:00.000Z',
      do_not_contact_by_zoho_id: 'Zrecruit_10000000000000101',
      do_not_contact_reason: 'Zoho Recruit: NEVER to be contacted again (set by Kristina Testova on 01 Mar 2024)',
    })
  })

  it('contact_later comes from association statuses only', () => {
    const later = never({ 'Candidate Status': 'Contact in Future' })
    expect(contactFlags({ candidate: base, associations: [later], notes: [], users, tz: TZ })).toMatchObject({ do_not_contact: false, contact_later: true })
    const hirable = never({ 'Candidate Status': 'Rejected-Hirable' })
    expect(contactFlags({ candidate: base, associations: [hirable], notes: [], users, tz: TZ }).contact_later).toBe(true)
    const candidateOnly = cand({ 'Candidate Status': 'Contact in Future' })
    expect(contactFlags({ candidate: candidateOnly, associations: [], notes: [], users, tz: TZ }).contact_later).toBe(false)
  })

  it('never wins over later when both appear', () => {
    const r = contactFlags({ candidate: base, associations: [never({}), never({ 'Associated Id': 'Zrecruit_7', 'Candidate Status': 'Contact in Future' })], notes: [], users, tz: TZ })
    expect(r).toMatchObject({ do_not_contact: true, contact_later: false })
  })
})

describe('buildPayload over the synthetic export', () => {
  const exp = readExport(path.join(FIXTURES, 'Data'))
  const result = buildPayload(exp, { tz: TZ, exportedAt: '2026-09-21T00:00:00.000Z' })
  const { payload, review, counts } = result
  const candidates = Object.fromEntries(payload.candidates.map((c) => [c.zoho_id, c]))
  const applications = Object.fromEntries(payload.applications.map((a) => [a.zoho_id, a]))
  const jobs = Object.fromEntries(payload.jobs.map((j) => [j.zoho_id, j]))

  it('reports no unknown statuses or sources', () => {
    expect(result.unknown).toEqual({ statuses: [], sources: [] })
    expect(review.unknown_statuses).toEqual([])
    expect(review.unknown_sources).toEqual([])
  })

  it('users carry id, email and name', () => {
    expect(payload.users).toEqual([
      { zoho_id: 'Zrecruit_10000000000000101', email: 'recruiter@example.test', name: 'Kristina Testova' },
      { zoho_id: 'Zrecruit_10000000000000102', email: 'hr@example.test', name: 'HR Generic' },
    ])
    expect(payload.timezone_assumed).toBe(TZ)
    expect(payload.exported_at).toBe('2026-09-21T00:00:00.000Z')
  })

  it('jobs: title fallback, department → company, statuses, dates and custom.zoho', () => {
    expect(jobs['Zrecruit_10000000000000301']).toMatchObject({
      display_id: 'ZR_1_JOB', company_code: 'HUT4', title: 'Frontend Developer', description: 'Build the front end.', status: 'filled',
      created_at: '2024-01-10T08:00:00.000Z', modified_at: '2024-03-02T09:00:00.000Z', date_closed: '2024-02-29T23:00:00.000Z',
      custom: { zoho: { id: 'Zrecruit_10000000000000301', display_id: 'ZR_1_JOB', department: 'HUT 4', hiring_manager_email: 'recruiter@example.test',
        recruiters: ['Kristina Testova'], target_date: '2024-02-28', date_opened: '2024-01-10', date_closed: '2024-03-01', headcount: 1, close_date_assumed: false } },
    })
    expect(jobs['Zrecruit_10000000000000302']).toMatchObject({
      company_code: 'SYNA', title: 'Sales Lead', status: 'closed', date_closed: null,
      custom: { zoho: { department: 'Synami Products', recruiters: ['Kristina Testova', 'HR Generic'], headcount: 2, date_closed: null, close_date_assumed: true } },
    })
    expect(jobs['Zrecruit_10000000000000303']).toMatchObject({ company_code: 'LIQU', status: 'open' })
  })

  it('candidates: the column map applied, custom.zoho verbatim, education and links', () => {
    const c1 = candidates[C1]
    expect(c1).toMatchObject({
      display_id: 'ZR_1_CAND', full_name: 'Test Möllersten', email: 'test.one@example.test', phone: '+389 70 123 456',
      linkedin_url: 'https://www.linkedin.com/in/test-one/', source_key: 'head_hunt', current_title: 'Developer', current_employer: 'Example Corp',
      location: 'Skopje, North Macedonia', skills: ['Vue', 'TypeScript', 'SQL'], summary: null, referred_by: null,
      owner_zoho_id: 'Zrecruit_10000000000000101', created_at: '2024-01-12T13:15:00.000Z', updated_at: '2024-03-05T09:00:00.000Z',
      last_activity_at: '2024-03-06T07:00:00.000Z', do_not_contact: false, contact_later: true,
    })
    expect(c1.custom.zoho).toEqual({
      id: C1, display_id: 'ZR_1_CAND', status: 'Hired', stage: 'New', source: 'Head Hunt', owner_name: 'Kristina Testova',
      created_by_name: 'Kristina Testova', rating: 3, is_locked: false, fresh_candidate: false, experience_years: 5.5,
      current_salary: 1500, tags: ['Vue'],
    })
    expect(c1.custom.links).toEqual({ secondary_email: 'test.one.alt@example.test' })
    expect(c1.custom.education).toEqual([
      { institute: 'Example University', major: 'Computer Science', degree: 'BSc', from: '2014-09', to: '2018-06', current: false, zoho_row_id: 'Zrecruit_10000000000000901' },
    ])
    const c2 = candidates[C2]
    expect(c2).toMatchObject({
      full_name: 'Nom Deux', email: null, phone: '070 123 456', summary: 'Knows the product.', source_key: 'linkedin_ad', last_activity_at: '2024-02-20T08:00:00.000Z',
      do_not_contact: true, do_not_contact_reason: 'Status changed to NEVER: asked us not to call again.',
      do_not_contact_at: '2024-02-20T08:00:00.000Z', do_not_contact_by_zoho_id: 'Zrecruit_10000000000000101', contact_later: false,
    })
    expect(c2.custom.links).toEqual({ raw_email: 'not-an-email' })
    expect(c2.custom.zoho).toMatchObject({ status: 'Contacted', is_locked: true, fresh_candidate: true, rating: null, experience_years: null })
    expect(c2.custom.zoho).not.toHaveProperty('expected_salary')
    const c3 = candidates[C3]
    expect(c3).toMatchObject({ full_name: 'ZR_3_CAND', source_key: 'imported', location: 'Bitola', do_not_contact: false, contact_later: false })
    expect(c3.custom.zoho.status).toBe('Contact in Future')
    expect(c3.custom.education).toHaveLength(2)
    expect(c3.custom.education[0]).toMatchObject({ from: null, current: true })
  })

  it('applications: mapped stages, reasons, the stale rule and the hire facts', () => {
    expect(applications['Zrecruit_10000000000000501']).toMatchObject({
      candidate_zoho_id: C1, job_zoho_id: 'Zrecruit_10000000000000301', stage_key: 'hired', stale_closed: false, zoho_status: 'Hired', zoho_stage: 'Hired',
      withdrawn_reason: null, rejected_reason: null, received_at: '2024-01-12T13:20:00.000Z', modified_at: '2024-03-05T09:00:00.000Z',
      modified_by_zoho_id: 'Zrecruit_10000000000000101', hired_date: '2024-03-04', hired_by_zoho_id: 'Zrecruit_10000000000000101',
      sub_status_key: null,
      custom: { zoho: { created_by: 'Kristina Testova' } },
    })
    expect(applications['Zrecruit_10000000000000502']).toMatchObject({
      stage_key: 'screening', stale_closed: true, close_date: '2024-05-09T09:30:00.000Z', close_date_assumed: true, withdrawn_reason: 'Job closed', hired_date: null, hired_by_zoho_id: null,
      // The D5 sub-status guess (Contacted → contacted) is kept even though the application is stale-closed.
      sub_status_key: 'contacted',
    })
    expect(applications['Zrecruit_10000000000000503']).toMatchObject({ stage_key: 'withdrawn', stale_closed: false, withdrawn_reason: 'Do not contact', close_date: null, close_date_assumed: false, sub_status_key: null })
    expect(applications['Zrecruit_10000000000000504']).toMatchObject({ stage_key: 'rejected', rejected_reason: 'Rejected, hirable later', withdrawn_reason: null, sub_status_key: null })
  })

  it('notes: the pair and the interview route attach, the rest are counted', () => {
    expect(payload.notes).toHaveLength(2)
    const byId = Object.fromEntries(payload.notes.map((n) => [n.zoho_id, n]))
    expect(byId['Zrecruit_10000000000000601']).toEqual({
      zoho_id: 'Zrecruit_10000000000000601', application_zoho_id: 'Zrecruit_10000000000000501', kind: 'Call',
      body: '[Zoho Call · 01 Feb 2024 · Kristina Testova] First call.\nSecond line, with a comma and a "quote" — @Kristina Testova to follow up.',
      actor_zoho_id: 'Zrecruit_10000000000000101', actor_name: 'Kristina Testova', created_at: '2024-02-01T14:00:00.000Z',
    })
    expect(byId['Zrecruit_10000000000000603']).toMatchObject({ application_zoho_id: 'Zrecruit_10000000000000501', kind: 'Interview Feedback' })
    // 606 (a LinkedIn message) and 607 (a job the export does not carry) are
    // the person-level notes plan 055 imports; 052 only counts them.
    expect(counts.notes).toEqual({ attached: 2, without_application: 4, skipped_modules: 1 })
  })

  it('counts and the review file', () => {
    expect(counts.candidates).toBe(3)
    expect(counts.applications).toEqual({ hired: 1, screening: 1, withdrawn: 1, rejected: 1, stale: 1 })
    expect(counts.do_not_contact).toBe(1)
    expect(counts.contact_later).toBe(1)
    expect(counts.jobs).toEqual({ HUT4: 1, SYNA: 1, LIQU: 1 })
    expect(counts.unresolved_departments).toBe(0)
    expect(counts.problems).toBe(0)
    expect(review.never_associated.map((c) => c.zoho_id)).toEqual([C3])
    expect(review.stale_applications.map((a) => a.zoho_id)).toEqual(['Zrecruit_10000000000000502'])
    expect(review.hires).toHaveLength(1)
    expect(review.hires[0]).toMatchObject({ application_zoho_id: 'Zrecruit_10000000000000501', hired_date: '2024-03-04', job: { title: 'Frontend Developer', company_code: 'HUT4' } })
    expect(review.same_linkedin_by_key).toEqual([[C1, C2]])
    expect(review.same_linkedin_by_url).toEqual([])
    expect(review.same_name_groups).toEqual([])
    expect(review.column_map).toBe(COLUMN_MAP)
    expect(review.problems).toEqual([])
  })

  it('records a date it cannot read as a problem, not a crash', () => {
    const broken = { ...exp, candidates: exp.candidates.map((c) => (c['Candidate Id'] === C3 ? { ...c, 'Created Time': '31/12/2025 10:00 AM' } : c)) }
    const r = buildPayload(broken, { tz: TZ, exportedAt: 'x' })
    expect(r.review.problems).toEqual([{ kind: 'candidate', ref: C3, message: 'Created Time "31/12/2025 10:00 AM" is not a date' }])
    expect(r.payload.candidates.find((c) => c.zoho_id === C3)?.created_at).toBeNull()
  })

  it('records an association whose job is not in the export as a problem and leaves it out', () => {
    const orphan = { ...exp.associations[0], 'Associated Id': 'Zrecruit_10000000000000599', 'Job Opening ID': 'Zrecruit_10000000000000999' }
    const r = buildPayload({ ...exp, associations: [...exp.associations, orphan] }, { tz: TZ, exportedAt: 'x' })
    expect(r.payload.applications).toHaveLength(payload.applications.length)
    expect(r.counts.problems).toBe(1)
    expect(r.review.problems).toEqual([
      { kind: 'application', ref: 'Zrecruit_10000000000000599', message: 'Job Opening ID "Zrecruit_10000000000000999" is not in the jobs export' },
    ])
  })
})

describe('zoho-recruit-extract.ts end to end over the fixture folder', () => {
  it('writes the payload, the manifest and the review, prints counts only and exits 0', () => {
    const outDir = fs.mkdtempSync(path.join(os.tmpdir(), 'zoho-extract-'))
    const script = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../scripts/zoho-recruit-extract.ts')
    const out = path.join(outDir, 'payload.json')
    const files = path.join(outDir, 'files.json')
    const review = path.join(outDir, 'review.json')
    const run = spawnSync('npx', ['tsx', script, path.join(FIXTURES, 'Data'), path.join(FIXTURES, 'Attachments'), '--tz', TZ, '--out', out, '--files', files, '--review', review], {
      cwd: path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..'),
      encoding: 'utf8',
      shell: process.platform === 'win32',
    })
    try {
      expect(run.status, run.stderr).toBe(0)
      expect(run.stdout).toContain('[zoho-extract] candidates: 3')
      expect(run.stdout).toContain('[zoho-extract] do_not_contact: 1 · contact_later: 1')
      expect(run.stdout).toContain('[zoho-extract] files: eligible 4 · text-only 1 · skipped 1')
      expect(run.stdout).toContain('unknown statuses: [] · unknown sources: []')
      expect(run.stdout).not.toMatch(/example\.test|Testova|Deux/)
      const payload = JSON.parse(fs.readFileSync(out, 'utf8'))
      expect(payload.candidates).toHaveLength(3)
      expect(payload.applications).toHaveLength(4)
      expect(JSON.parse(fs.readFileSync(files, 'utf8'))).toHaveLength(4)
      const rv = JSON.parse(fs.readFileSync(review, 'utf8'))
      expect(rv.files_skipped).toEqual({ 'calendar invite': 1 })
      expect(rv.unresolvable_files).toHaveLength(1)
    } finally {
      fs.rmSync(outDir, { recursive: true, force: true })
    }
  }, 60_000)
})
