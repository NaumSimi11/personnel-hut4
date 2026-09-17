import { describe, expect, it } from 'vitest'
import { isStaleBuildError } from './staleBuild'

describe('isStaleBuildError', () => {
  it('recognises a chunk that no longer exists on the server', () => {
    // What the browser says when a deploy replaced the file this tab expects.
    expect(isStaleBuildError(new TypeError(
      'Failed to fetch dynamically imported module: https://app/assets/HomePage-BP84x4BW.js',
    ))).toBe(true)
  })

  it('recognises the MIME complaint from an SPA fallback serving index.html', () => {
    expect(isStaleBuildError(new TypeError(
      'Failed to load module script: Expected a JavaScript-or-Wasm module script but the server responded with a MIME type of "text/html".',
    ))).toBe(true)
  })

  it('recognises the wording other browsers use', () => {
    expect(isStaleBuildError(new TypeError('error loading dynamically imported module'))).toBe(true)
    expect(isStaleBuildError(new TypeError('Importing a module script failed.'))).toBe(true)
  })

  it('leaves ordinary failures alone, so real bugs still surface', () => {
    expect(isStaleBuildError(new TypeError('Cannot read properties of undefined'))).toBe(false)
    expect(isStaleBuildError(new Error('Network request failed'))).toBe(false)
    expect(isStaleBuildError(null)).toBe(false)
    expect(isStaleBuildError('a string')).toBe(false)
  })
})
