import { describe, expect, it } from 'vitest'
import { likePattern } from './likePattern'

describe('likePattern', () => {
  it('wraps the trimmed term in wildcards', () => {
    expect(likePattern('  ana ')).toBe('%ana%')
  })
  it('makes % _ and \\ literal', () => {
    expect(likePattern('50%_a\\b')).toBe('%50\\%\\_a\\\\b%')
  })
})
