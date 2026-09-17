import { describe, expect, it } from 'vitest'
import { bonusInput, defaultPeriod, netEstimate, payrollActions, payrollSettingsInput, periodInput, periodStatusLabel, periodTotals, payrollCsv } from './payroll'

describe('periodInput / defaultPeriod', () => {
  it('needs a valid range and a currency; the default is the current month', () => {
    expect(periodInput.safeParse({ start: '2026-09-01', end: '2026-09-30', currency: 'eur', note: '' }).success).toBe(true)
    expect(periodInput.safeParse({ start: '2026-09-30', end: '2026-09-01', currency: 'EUR', note: '' }).success).toBe(false)
    expect(periodInput.safeParse({ start: '2026-09-01', end: '2026-09-30', currency: 'euro', note: '' }).success).toBe(false)
    expect(defaultPeriod('2026-09-12')).toEqual({ start: '2026-09-01', end: '2026-09-30' })
    expect(defaultPeriod('2026-02-03')).toEqual({ start: '2026-02-01', end: '2026-02-28' })
  })
})

describe('payrollActions', () => {
  const can = (caps: string[]) => (cap: string) => caps.includes(cap)
  it('mirrors the functions: prepare again while in review, approve by someone else, export once approved', () => {
    expect(payrollActions({ status: 'in_review', prepared_by: 'me' }, 'me', can(['payroll.individual', 'payroll.approve'])).map((a) => a.key)).toEqual(['reprepare'])
    expect(payrollActions({ status: 'in_review', prepared_by: 'other' }, 'me', can(['payroll.approve'])).map((a) => a.key)).toEqual(['approve'])
    expect(payrollActions({ status: 'approved', prepared_by: 'other' }, 'me', can(['payroll.export', 'payroll.approve'])).map((a) => a.key)).toEqual(['export', 'reopen'])
    expect(payrollActions({ status: 'exported', prepared_by: 'other' }, 'me', can(['payroll.export']))).toEqual([])
    expect(periodStatusLabel('in_review')).toBe('In review')
  })
  it('hides Approve on a reopened period until it is prepared again', () => {
    expect(payrollActions({ status: 'in_review', prepared_by: 'other', reopened_at: '2026-09-10T10:00:00Z' }, 'me', can(['payroll.individual', 'payroll.approve'])).map((a) => a.key)).toEqual(['reprepare'])
  })
})

describe('netEstimate / periodTotals', () => {
  it('mirrors the database: gross = amount + bonus, tax on the gross, net after the flat deduction, cents rounded', () => {
    expect(netEstimate({ amount: 1200, bonus: 250, taxRatePercent: 10, deductionsFlat: 50 })).toEqual({ gross: 1450, tax: 145, net: 1255 })
    expect(netEstimate({ amount: 1000.33, bonus: 0, taxRatePercent: 12.5, deductionsFlat: 0 })).toEqual({ gross: 1000.33, tax: 125.04, net: 875.29 })
    expect(netEstimate({ amount: 1000, bonus: 0, taxRatePercent: 0, deductionsFlat: 0 })).toEqual({ gross: 1000, tax: 0, net: 1000 })
  })
  it('sums the lines', () => {
    const line = { full_name: 'A', job_title: 'B', currency: 'EUR', pay_basis_key: 'monthly', effective_from: '2026-09-01', effective_to: '2026-09-30', days_covered: 30 }
    expect(
      periodTotals([
        { ...line, amount: 1200, bonus: 250, gross: 1450, tax: 145, deductions: 50, net: 1255 },
        { ...line, amount: 800, bonus: 0, gross: 800, tax: 80, deductions: 50, net: 670 },
      ]),
    ).toEqual({ amount: 2000, bonus: 250, gross: 2250, tax: 225, deductions: 100, net: 1925 })
  })
})

describe('bonusInput / payrollSettingsInput', () => {
  it('needs a person, an amount above zero, a currency, a reason and a date', () => {
    const ok = bonusInput.safeParse({ person_id: 'p', amount: '250', currency: 'eur', reason: ' Quarter bonus ', item_date: '2026-09-10' })
    expect(ok.success).toBe(true)
    if (ok.success) expect(ok.data).toEqual({ person_id: 'p', amount: 250, currency: 'EUR', reason: 'Quarter bonus', item_date: '2026-09-10' })
    expect(bonusInput.safeParse({ person_id: '', amount: '250', currency: 'EUR', reason: 'x', item_date: '2026-09-10' }).success).toBe(false)
    expect(bonusInput.safeParse({ person_id: 'p', amount: '0', currency: 'EUR', reason: 'x', item_date: '2026-09-10' }).success).toBe(false)
    expect(bonusInput.safeParse({ person_id: 'p', amount: 'abc', currency: 'EUR', reason: 'x', item_date: '2026-09-10' }).success).toBe(false)
    expect(bonusInput.safeParse({ person_id: 'p', amount: '10', currency: 'EUR', reason: '  ', item_date: '2026-09-10' }).success).toBe(false)
    expect(bonusInput.safeParse({ person_id: 'p', amount: '10', currency: 'EUR', reason: 'x', item_date: '' }).success).toBe(false)
  })
  it('keeps the rate between 0 and 100 and the deduction non-negative', () => {
    const ok = payrollSettingsInput.safeParse({ tax_rate_percent: '10', deductions_flat: '50' })
    expect(ok.success).toBe(true)
    if (ok.success) expect(ok.data).toEqual({ tax_rate_percent: 10, deductions_flat: 50 })
    expect(payrollSettingsInput.safeParse({ tax_rate_percent: '150', deductions_flat: '0' }).success).toBe(false)
    expect(payrollSettingsInput.safeParse({ tax_rate_percent: '10', deductions_flat: '-1' }).success).toBe(false)
    expect(payrollSettingsInput.safeParse({ tax_rate_percent: '', deductions_flat: '' }).success).toBe(true)
  })
})

describe('payrollCsv', () => {
  it('writes one row per line with neutralised formula cells', () => {
    const csv = payrollCsv(
      { period_start: '2026-09-01', period_end: '2026-09-30', currency: 'EUR' },
      [{ full_name: '=Ana', job_title: 'Clerk', amount: 1200.5, currency: 'EUR', pay_basis_key: 'monthly', effective_from: '2026-09-01', effective_to: '2026-09-30', days_covered: 30, bonus: 100, gross: 1300.5, tax: 130.05, deductions: 50, net: 1120.45 }],
    )
    const lines = csv.split('\n')
    expect(lines[0]).toBe('Person,Job title,Amount,Currency,Pay basis,From,To,Days covered,Bonus,Gross,Tax,Deductions,Net')
    expect(lines[1]).toBe(`"'=Ana",Clerk,1200.50,EUR,monthly,2026-09-01,2026-09-30,30,100.00,1300.50,130.05,50.00,1120.45`)
  })
})
