import { describe, expect, it } from 'vitest'
import { extensionFor } from './applicationFiles'
import { CANDIDATE_FILE_KINDS, candidateFileObjectPath } from './candidateFiles'

describe('extensionFor', () => {
  it('names the extension for every accepted type', () => {
    expect(extensionFor('application/pdf')).toBe('pdf')
    expect(extensionFor('application/msword')).toBe('doc')
    expect(extensionFor('application/vnd.openxmlformats-officedocument.wordprocessingml.document')).toBe('docx')
    expect(extensionFor('text/plain')).toBe('txt')
    expect(extensionFor('image/png')).toBe('png')
    expect(extensionFor('image/jpeg')).toBe('jpg')
  })
  it('falls back to bin for anything else', () => {
    expect(extensionFor('application/zip')).toBe('bin')
    expect(extensionFor('')).toBe('bin')
  })
})

describe('candidateFileObjectPath', () => {
  it('keys the object under candidate/<candidate>/<file>.<ext>, the shape the storage policy resolves', () => {
    expect(candidateFileObjectPath('cand-1', 'file-1', 'application/pdf')).toBe('candidate/cand-1/file-1.pdf')
    expect(
      candidateFileObjectPath('cand-1', 'file-1', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document'),
    ).toBe('candidate/cand-1/file-1.docx')
    expect(candidateFileObjectPath('cand-1', 'file-1', 'image/jpeg')).toBe('candidate/cand-1/file-1.jpg')
  })
})

describe('CANDIDATE_FILE_KINDS', () => {
  it('offers the five kinds of candidate_files.kind with CV first', () => {
    expect(CANDIDATE_FILE_KINDS.map((k) => k.key)).toEqual(['cv', 'cover_letter', 'portfolio', 'profile', 'other'])
    expect(CANDIDATE_FILE_KINDS.map((k) => k.label)).toEqual([
      'CV',
      'Cover letter',
      'Portfolio',
      'Profile capture (text)',
      'Other',
    ])
  })
})
