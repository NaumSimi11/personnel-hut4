import { describe, expect, it } from 'vitest'
import { bandFields, parseSalaryBand } from './salaryBand'

describe('salary band', () => {
  it('is optional', () => {
    expect(parseSalaryBand('', '', 'EUR')).toEqual({ band: null, error: null })
  })
  it('reads amounts with separators and either end alone', () => {
    expect(parseSalaryBand('30,000', '40 000', 'eur')).toEqual({ band: { min: 30000, max: 40000, currency: 'EUR' }, error: null })
    expect(parseSalaryBand('', '50000', 'MKD').band).toEqual({ min: null, max: 50000, currency: 'MKD' })
  })
  it('refuses a reversed band, a missing currency and nonsense', () => {
    expect(parseSalaryBand('5', '1', 'EUR').error).toMatch(/lower end/)
    expect(parseSalaryBand('5', '', '').error).toMatch(/currency/)
    expect(parseSalaryBand('lots', '', 'EUR').error).toMatch(/plain amounts/)
  })
  it('fills the form back from a stored band', () => {
    expect(bandFields({ min: 30000, max: null, currency: 'EUR' })).toEqual({ bandMin: '30000', bandMax: '', bandCurrency: 'EUR' })
    expect(bandFields(null)).toEqual({ bandMin: '', bandMax: '', bandCurrency: 'EUR' })
  })
})
