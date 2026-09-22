import { describe, expect, it } from 'vitest'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { readExport } from './csv.js'
import {
  FILE_MAX_BYTES,
  buildFilesManifest,
  classifyAttachment,
  htmlToText,
  isGenericAccount,
  mimeFor,
  originalNameOf,
  parseCsvSize,
  planUpload,
  profileCaptureName,
  type AttachmentRow,
  type DiskStat,
  type ManifestRow,
} from './files.js'

const FIXTURES = path.join(path.dirname(fileURLToPath(import.meta.url)), 'fixtures')
const onDisk: DiskStat = { exists: true, size_bytes: 1234 }
const candidate = { kind: 'candidate' as const, candidateZohoId: 'Zrecruit_1' }

function row(over: Partial<AttachmentRow>): AttachmentRow {
  return { attachmentId: 'Zrecruit_9', fileName: '10000000000000001_Test CV.pdf', category: 'Zrecruit_Resume', parent: candidate, ...over }
}

describe('parseCsvSize', () => {
  it('reads a plain number and strips the one " bytes" suffix', () => {
    expect(parseCsvSize('12345')).toBe(12345)
    expect(parseCsvSize('12345 bytes')).toBe(12345)
    expect(parseCsvSize('')).toBeNull()
    expect(parseCsvSize('n/a')).toBeNull()
  })
})

describe('originalNameOf', () => {
  it('drops the 17-digit prefix, normalises to NFC and caps at 200', () => {
    expect(originalNameOf('10000000000000001_Test CV.pdf')).toBe('Test CV.pdf')
    expect(originalNameOf('Möllersten.pdf')).toBe('Möllersten.pdf')
    expect(originalNameOf('1_' + 'x'.repeat(300) + '.pdf')).toHaveLength(200)
    expect(originalNameOf('')).toBe('file')
  })
})

describe('mimeFor', () => {
  it('knows the stored types', () => {
    expect(mimeFor('a.PDF')).toBe('application/pdf')
    expect(mimeFor('a.doc')).toBe('application/msword')
    expect(mimeFor('a.docx')).toBe('application/vnd.openxmlformats-officedocument.wordprocessingml.document')
    expect(mimeFor('a.jpg')).toBe('image/jpeg')
    expect(mimeFor('a.png')).toBe('image/png')
    expect(mimeFor('a.html')).toBe('text/html')
    expect(mimeFor('a.xyz')).toBeNull()
  })
})

describe('isGenericAccount', () => {
  it('hr@ and admin@ never name a person; any other work email may', () => {
    expect(isGenericAccount('hr@example.test')).toBe(true)
    expect(isGenericAccount(' Admin@Example.test ')).toBe(true)
    expect(isGenericAccount('ana@example.test')).toBe(false)
    expect(isGenericAccount(null)).toBe(false)
  })
})

describe('classifyAttachment', () => {
  it('a resume pdf / doc / docx / jpg / png is a cv', () => {
    for (const ext of ['pdf', 'doc', 'docx', 'jpg', 'png']) {
      expect(classifyAttachment(row({ fileName: `1_cv.${ext}` }), onDisk), ext)
        .toEqual({ candidateZohoId: 'Zrecruit_1', kind: 'cv', textOnly: false })
    }
  })

  it('a resume .html is a text-only profile capture', () => {
    expect(classifyAttachment(row({ fileName: '1_profile.html' }), onDisk))
      .toEqual({ candidateZohoId: 'Zrecruit_1', kind: 'profile', textOnly: true })
  })

  it('cover letters, others and offers keep their kind; the offer keeps its category', () => {
    expect(classifyAttachment(row({ category: 'Zrecruit_Cover Letter' }), onDisk))
      .toEqual({ candidateZohoId: 'Zrecruit_1', kind: 'cover_letter', textOnly: false })
    expect(classifyAttachment(row({ category: 'Zrecruit_Others' }), onDisk))
      .toEqual({ candidateZohoId: 'Zrecruit_1', kind: 'other', textOnly: false })
    expect(classifyAttachment(row({ category: 'Zrecruit_Offer' }), onDisk))
      .toEqual({ candidateZohoId: 'Zrecruit_1', kind: 'other', textOnly: false, category: 'Offer' })
  })

  it('a blank category with a note parent resolves through the note: cv when the name says so', () => {
    const viaNote = { kind: 'note' as const, candidateZohoId: 'Zrecruit_2' }
    expect(classifyAttachment(row({ category: '', parent: viaNote, fileName: '1_My CV 2024.docx' }), onDisk))
      .toEqual({ candidateZohoId: 'Zrecruit_2', kind: 'cv', textOnly: false })
    expect(classifyAttachment(row({ category: '', parent: viaNote, fileName: '1_resume.pdf' }), onDisk).kind).toBe('cv')
    expect(classifyAttachment(row({ category: '', parent: viaNote, fileName: '1_certificate.pdf' }), onDisk))
      .toEqual({ candidateZohoId: 'Zrecruit_2', kind: 'other', textOnly: false })
  })

  it('skips with a reason: ICS, job summaries, xlsx / msg / rar, job- or interview-parented, over 10 MB, missing', () => {
    const skip = (r: AttachmentRow, disk: DiskStat = onDisk) => {
      const c = classifyAttachment(r, disk)
      return c.kind === 'skip' ? c.reason : `NOT SKIPPED (${c.kind})`
    }
    expect(skip(row({ category: 'Zrecruit_ICS', fileName: '1_invite.ics', parent: { kind: 'interview', candidateZohoId: null } }))).toBe('calendar invite')
    expect(skip(row({ category: 'Zrecruit_Job Summary', parent: { kind: 'job', candidateZohoId: null } }))).toBe('job summary')
    expect(skip(row({ fileName: '1_sheet.xlsx' }))).toBe('unsupported type .xlsx')
    expect(skip(row({ fileName: '1_mail.msg' }))).toBe('unsupported type .msg')
    expect(skip(row({ fileName: '1_archive.rar' }))).toBe('unsupported type .rar')
    expect(skip(row({ category: 'Zrecruit_Others', parent: { kind: 'job', candidateZohoId: null } }))).toBe('attached to a job')
    expect(skip(row({ category: 'Zrecruit_Others', parent: { kind: 'interview', candidateZohoId: null } }))).toBe('attached to an interview')
    expect(skip(row({}), { exists: true, size_bytes: FILE_MAX_BYTES + 1 })).toBe('over 10 MB')
    expect(skip(row({}), { exists: false, size_bytes: null })).toBe('not on disk')
    expect(skip(row({ category: '', parent: { kind: 'unknown', candidateZohoId: null } }))).toBe('parent not a candidate')
    expect(skip(row({ category: 'Zrecruit_Something' }))).toBe('unknown category Zrecruit_Something')
  })

  it('a skipped row still names the candidate when it has one', () => {
    const c = classifyAttachment(row({ fileName: '1_sheet.xlsx' }), onDisk)
    expect(c.candidateZohoId).toBe('Zrecruit_1')
  })
})

describe('htmlToText', () => {
  it('strips tags, scripts, styles and entities, and collapses whitespace', () => {
    const html = '<html><head><title>T</title><style>p{color:red}</style></head><body>' +
      '<h1>Nom &amp; Deux</h1><p>Sales &nbsp; lead &#169; &#x41;</p><script>x()</script>' +
      '<ul><li>one</li><li>two</li></ul>   <div>end</div></body></html>'
    expect(htmlToText(html)).toBe('T\nNom & Deux\nSales lead © A\none\ntwo\nend')
  })

  it('caps at 100 kB', () => {
    expect(htmlToText('<p>' + 'a'.repeat(200_000) + '</p>')).toHaveLength(100 * 1024)
  })

  it('strips a raw NUL; Postgres text can\'t hold one', () => {
    expect(htmlToText('<p>Sales\u0000 lead</p>')).toBe('Sales lead')
  })
})

describe('buildFilesManifest', () => {
  it('runs over the synthetic export: eligible rows in, skips counted by reason', () => {
    const exp = readExport(path.join(FIXTURES, 'Data'))
    const result = buildFilesManifest(exp, path.join(FIXTURES, 'Attachments'), 'Europe/Skopje')
    const byId = Object.fromEntries(result.manifest.map((m) => [m.attachment_id, m]))
    expect(result.manifest).toHaveLength(4)
    expect(byId['Zrecruit_10000000000000801']).toMatchObject({
      candidate_zoho_id: 'Zrecruit_10000000000000201', kind: 'cv', original_name: 'Test CV.pdf',
      mime: 'application/pdf', size_bytes: 18, text_only: false, owner_email: 'recruiter@example.test',
      created_at: '2024-01-13T09:00:00.000Z',
    })
    expect(byId['Zrecruit_10000000000000802']).toMatchObject({ kind: 'profile', text_only: true, mime: 'text/plain' })
    expect(byId['Zrecruit_10000000000000804']).toMatchObject({ candidate_zoho_id: 'Zrecruit_10000000000000203', kind: 'cv' })
    expect(byId['Zrecruit_10000000000000805']).toMatchObject({ kind: 'other', category: 'Offer' })
    expect(result.skipped).toEqual({ 'calendar invite': 1 })
    expect(result.unresolvable).toEqual([{ attachment_id: 'Zrecruit_10000000000000803', reason: 'calendar invite', category: 'Zrecruit_ICS' }])
    expect(result.counts).toEqual({ eligible: 4, text_only: 1, skipped: 1 })
    expect(path.isAbsolute(byId['Zrecruit_10000000000000801'].path)).toBe(true)
  })
})

describe('planUpload', () => {
  const base: ManifestRow = {
    attachment_id: 'Zrecruit_10000000000000801', candidate_zoho_id: 'Zrecruit_1', kind: 'cv', path: 'E:/x/1_Test CV.pdf', original_name: 'Test CV.pdf',
    mime: 'application/pdf', size_bytes: 18, created_at: '2024-01-13T09:00:00.000Z', text_only: false, owner_email: null,
  }
  const candidateId = '0f2ad5d0-6f5e-4c4c-9b34-6d4c1b1a2a11'
  const fileId = '7b3e1b2c-1111-4222-8333-944455556666'

  it('a stored file: the path under the candidate, the original name and mime kept', () => {
    expect(planUpload(base, candidateId, fileId, 'Europe/Skopje')).toEqual({
      file_id: fileId, candidate_id: candidateId, kind: 'cv', storage_path: `candidate/${candidateId}/${fileId}.pdf`,
      original_name: 'Test CV.pdf', mime_type: 'application/pdf', text_only: false, created_at: '2024-01-13T09:00:00.000Z',
      provider_ref: 'Zrecruit_10000000000000801',
    })
  })

  it('a text-only capture: .txt, text/plain, named by its local date', () => {
    const capture = { ...base, kind: 'profile' as const, mime: 'text/plain', text_only: true, original_name: 'Nom Deux.html' }
    expect(planUpload(capture, candidateId, fileId, 'Europe/Skopje')).toMatchObject({
      storage_path: `candidate/${candidateId}/${fileId}.txt`, original_name: 'LinkedIn profile capture (13 Jan 2024).txt', mime_type: 'text/plain', text_only: true,
    })
    expect(profileCaptureName(null, 'Europe/Skopje')).toBe('LinkedIn profile capture (undated).txt')
  })
})
