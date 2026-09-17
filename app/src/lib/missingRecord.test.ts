import { describe, expect, it } from 'vitest'
import { missingRecordMessage } from './missingRecord'

describe('missingRecordMessage', () => {
  it('blames the lookup, not access, when the query itself failed', () => {
    const message = missingRecordMessage({
      noun: 'person',
      lookupFailed: true,
      seesEverything: false,
    })
    expect(message).toBe('Could not load this person. Please try again.')
  })

  it('says the record is gone when the viewer can see everything', () => {
    // RLS filters rather than errors, so an empty result is ambiguous — unless
    // the viewer is a platform admin, for whom visibility is guaranteed and
    // absence therefore proves the row is gone.
    const message = missingRecordMessage({
      noun: 'person',
      lookupFailed: false,
      seesEverything: true,
    })
    expect(message).toBe('This person no longer exists — the record was deleted.')
  })

  it('keeps both possibilities open for a viewer whose sight is limited', () => {
    const message = missingRecordMessage({
      noun: 'person',
      lookupFailed: false,
      seesEverything: false,
    })
    expect(message).toBe('This person does not exist, or you do not have access to them.')
  })

  it('never claims deletion it cannot prove', () => {
    const limited = missingRecordMessage({
      noun: 'company',
      lookupFailed: false,
      seesEverything: false,
    })
    expect(limited).not.toMatch(/deleted/)
  })

  it('carries the noun of whichever record is missing', () => {
    expect(
      missingRecordMessage({ noun: 'company', lookupFailed: false, seesEverything: true }),
    ).toBe('This company no longer exists — the record was deleted.')
    expect(
      missingRecordMessage({ noun: 'job', lookupFailed: true, seesEverything: true }),
    ).toBe('Could not load this job. Please try again.')
  })

  it('reads naturally for a record referred to in the plural', () => {
    expect(
      missingRecordMessage({
        noun: 'person',
        lookupFailed: false,
        seesEverything: false,
        plural: 'them',
      }),
    ).toBe('This person does not exist, or you do not have access to them.')
    expect(
      missingRecordMessage({
        noun: 'company',
        lookupFailed: false,
        seesEverything: false,
        plural: 'it',
      }),
    ).toBe('This company does not exist, or you do not have access to it.')
  })
})
