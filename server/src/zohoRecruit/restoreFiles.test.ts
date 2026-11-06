import { describe, expect, it } from 'vitest'
import { parseCsv } from './csv.js'
import { planRestore } from './restoreFiles.js'

// The backup's shape: the old import keyed Zoho candidates by Zoho's internal
// id (provider_ref "Zrecruit_…"); the display id the new import uses
// (ZR_…_CAND) sits in custom.zoho.display_id.
const zoho = (displayId: string) => `"{""zoho"": {""display_id"": ""${displayId}""}}"`
const candidates = parseCsv(
  [
    'id,full_name,provider,provider_ref,custom',
    `c-zoho,A,zoho_recruit,Zrecruit_101,${zoho('ZR_1_CAND')}`,
    'c-manual,B,manual,,{}',
    `c-gone,C,zoho_recruit,Zrecruit_109,${zoho('ZR_9_CAND')}`,
  ].join('\n'),
)
const fileHeader = 'id,candidate_id,kind,storage_path,original_name,mime_type,size_bytes,uploaded_by,extracted_text,provider,provider_ref,created_at'
const files = parseCsv(
  [
    fileHeader,
    'f1,c-zoho,cv,candidate/c-zoho/f1.pdf,a.pdf,application/pdf,120,p1,"line one\nline two",zoho_recruit,ATT_1,2026-01-02T03:04:05+00',
    'f2,c-manual,cv,candidate/c-manual/f2.docx,b.docx,application/x,5,,,,,2026-01-02T03:04:05+00',
    'f3,c-gone,cv,candidate/c-gone/f3.pdf,c.pdf,application/pdf,7,,,,,2026-01-02T03:04:05+00',
    'f4,c-unknown,cv,candidate/c-unknown/f4.pdf,d.pdf,application/pdf,7,,,,,2026-01-02T03:04:05+00',
  ].join('\n'),
)

describe('planRestore', () => {
  const plan = planRestore(candidates, files, new Map([['ZR_1_CAND', 'new-1']]))

  it('maps a re-imported candidate to its new path, keeping the file id', () => {
    expect(plan.uploads).toHaveLength(1)
    const [u] = plan.uploads
    expect(u.fileId).toBe('f1')
    expect(u.from).toBe('candidate/c-zoho/f1.pdf')
    expect(u.to).toBe('candidate/new-1/f1.pdf')
    expect(u.row).toEqual({
      id: 'f1',
      candidate_id: 'new-1',
      kind: 'cv',
      storage_path: 'candidate/new-1/f1.pdf',
      original_name: 'a.pdf',
      mime_type: 'application/pdf',
      size_bytes: 120,
      uploaded_by: 'p1',
      extracted_text: 'line one\nline two',
      provider: 'zoho_recruit',
      provider_ref: 'ATT_1',
      created_at: '2026-01-02T03:04:05+00',
    })
  })

  it('skips manual candidates, ones not re-imported and ones missing from the backup', () => {
    expect(plan.skipped).toEqual([
      { fileId: 'f2', reason: 'manual candidate' },
      { fileId: 'f3', reason: 'not re-imported' },
      { fileId: 'f4', reason: 'candidate not in backup' },
    ])
  })

  it('turns empty nullable cells into null', () => {
    const f = { ...files[1], candidate_id: 'c-zoho', storage_path: 'candidate/c-zoho/f2.docx' }
    const q = planRestore(candidates, [f], new Map([['ZR_1_CAND', 'n']]))
    expect(q.uploads[0].row).toMatchObject({ uploaded_by: null, extracted_text: null, provider: null, provider_ref: null })
  })
})
