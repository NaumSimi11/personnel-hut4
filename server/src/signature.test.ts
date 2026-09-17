import { describe, expect, it } from 'vitest'
import { capacityFor, returnStatements, signatureProblem } from '../../shared/signature.js'

const PNG = 'data:image/png;base64,iVBORw0KGgoAAAANSUhEUg=='

describe('signatureProblem', () => {
  it('accepts a typed name', () => {
    expect(signatureProblem({ method: 'typed', name: 'Naum Simidjioski' })).toBeNull()
  })

  it('accepts a drawn signature with the name printed beneath', () => {
    expect(signatureProblem({ method: 'drawn', name: 'Naum Simidjioski', image: PNG })).toBeNull()
  })

  it('insists on a name even when the signature is drawn', () => {
    // A drawing nobody can read is not evidence of who signed.
    expect(signatureProblem({ method: 'drawn', name: '', image: PNG }))
      .toBe('Type your full name as your signature.')
  })

  it('refuses an empty drawing', () => {
    expect(signatureProblem({ method: 'drawn', name: 'Ana Ana', image: '' }))
      .toBe('Draw your signature, or switch to typing it.')
  })

  it('refuses anything that is not a PNG data URL', () => {
    for (const bad of ['https://example.test/sig.png', 'data:text/html,<script>', 'data:image/svg+xml;base64,PD8=']) {
      expect(signatureProblem({ method: 'drawn', name: 'Ana Ana', image: bad }))
        .toBe('That signature could not be read. Draw it again.')
    }
  })

  it('refuses an image large enough to be a screenshot', () => {
    const huge = 'data:image/png;base64,' + 'A'.repeat(1_400_001)
    expect(signatureProblem({ method: 'drawn', name: 'Ana Ana', image: huge }))
      .toBe('That signature is too large. Draw it again.')
  })

  it('ignores a drawing when the method is typed', () => {
    expect(signatureProblem({ method: 'typed', name: 'Ana Ana', image: 'rubbish' })).toBeNull()
  })
})

describe('returnStatements', () => {
  it('has the person confirm they handed it back and kept nothing', () => {
    const s = returnStatements('Synami')
    expect(s.person).toContain('handed back')
    expect(s.person).toContain('keep nothing further')
  })

  it('has HR confirm receipt for the company, and their authority to accept', () => {
    const s = returnStatements('Synami')
    expect(s.hr).toContain('on behalf of Synami')
    expect(s.hr).toContain('authorised to accept')
  })
})

describe('capacityFor', () => {
  it('distinguishes signing for yourself from signing for a company', () => {
    expect(capacityFor('person', 'Synami')).toBe('The person returning the equipment')
    expect(capacityFor('hr', 'Synami')).toBe('For Synami')
  })
})
