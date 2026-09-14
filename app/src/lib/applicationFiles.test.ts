import { describe, expect, it } from 'vitest'
import {
  FILE_KINDS,
  candidateNameFromFile,
  FILE_MAX_BYTES,
  fileObjectPath,
  formatBytes,
  validateApplicationFile,
} from './applicationFiles'

describe('validateApplicationFile', () => {
  it('accepts PDF, Word, text and images up to 10 MB', () => {
    for (const type of [
      'application/pdf',
      'application/msword',
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'text/plain',
      'image/png',
      'image/jpeg',
    ]) {
      expect(validateApplicationFile({ type, size: FILE_MAX_BYTES, name: 'cv.pdf' })).toBeNull()
    }
  })

  it('rejects other types and oversized files with readable messages', () => {
    expect(validateApplicationFile({ type: 'application/zip', size: 10, name: 'cv.zip' })).toBe(
      'Attach a PDF, Word document, text file or image.',
    )
    expect(validateApplicationFile({ type: 'application/pdf', size: FILE_MAX_BYTES + 1, name: 'cv.pdf' })).toBe(
      'Files must be 10 MB or smaller.',
    )
  })
})

describe('fileObjectPath', () => {
  it('keys the object by application and file id with the extension from the type', () => {
    expect(fileObjectPath('app-1', 'file-1', 'application/pdf')).toBe('app-1/file-1.pdf')
    expect(
      fileObjectPath('app-1', 'file-1', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document'),
    ).toBe('app-1/file-1.docx')
    expect(fileObjectPath('app-1', 'file-1', 'image/jpeg')).toBe('app-1/file-1.jpg')
  })
})

describe('formatBytes', () => {
  it('prints human sizes', () => {
    expect(formatBytes(512)).toBe('512 B')
    expect(formatBytes(2048)).toBe('2 KB')
    expect(formatBytes(3 * 1024 * 1024)).toBe('3.0 MB')
  })
})

describe('FILE_KINDS', () => {
  it('offers the four kinds with CV first', () => {
    expect(FILE_KINDS.map((k) => k.key)).toEqual(['cv', 'cover_letter', 'portfolio', 'other'])
  })
})

describe('candidateNameFromFile', () => {
  it('reads a person name out of the usual CV file names', () => {
    expect(candidateNameFromFile('Ana_Ilievska_CV.pdf')).toBe('Ana Ilievska')
    expect(candidateNameFromFile('cv-marko-petrov-2026.docx')).toBe('Marko Petrov')
    expect(candidateNameFromFile('Resume - Jovan Stojanov (final).pdf')).toBe('Jovan Stojanov')
    expect(candidateNameFromFile('CURRICULUM VITAE Elena.pdf')).toBe('Elena')
    expect(candidateNameFromFile('Bojan Ivanovski.PDF')).toBe('Bojan Ivanovski')
  })
  it('falls back to the file name without extension when nothing is left', () => {
    expect(candidateNameFromFile('CV.pdf')).toBe('CV')
    expect(candidateNameFromFile('2026.pdf')).toBe('2026')
  })
})
