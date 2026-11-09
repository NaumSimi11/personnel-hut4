import { describe, expect, it } from 'vitest'
import { linkedinHref } from './linkedin'

describe('linkedinHref', () => {
  it('keeps an https profile address as it is', () => {
    expect(linkedinHref('https://www.linkedin.com/in/aaron-zarb-662437207/')).toBe(
      'https://www.linkedin.com/in/aaron-zarb-662437207/',
    )
  })

  it('gives a bare address its https://', () => {
    expect(linkedinHref('  www.linkedin.com/in/someone  ')).toBe('https://www.linkedin.com/in/someone')
    expect(linkedinHref('linkedin.com/in/someone')).toBe('https://linkedin.com/in/someone')
  })

  it('allows http', () => {
    expect(linkedinHref('http://linkedin.com/in/someone')).toBe('http://linkedin.com/in/someone')
  })

  it('refuses anything that is not a web address', () => {
    expect(linkedinHref('javascript:alert(1)')).toBeNull()
    expect(linkedinHref('data:text/html,hi')).toBeNull()
    expect(linkedinHref('ask Ivana')).toBeNull()
    expect(linkedinHref('nothing')).toBeNull()
  })

  it('is null for nothing at all', () => {
    expect(linkedinHref(null)).toBeNull()
    expect(linkedinHref(undefined)).toBeNull()
    expect(linkedinHref('   ')).toBeNull()
  })
})
