import { describe, expect, it } from 'vitest'
import { defaultPeriod, payrollActions, periodInput, periodStatusLabel, payrollCsv } from './payroll'

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
})

describe('payrollCsv', () => {
  it('writes one row per line with neutralised formula cells', () => {
    const csv = payrollCsv(
      { period_start: '2026-09-01', period_end: '2026-09-30', currency: 'EUR' },
      [{ full_name: '=Ana', job_title: 'Clerk', amount: 1200.5, currency: 'EUR', pay_basis_key: 'monthly', effective_from: '2026-09-01', effective_to: '2026-09-30', days_covered: 30 }],
    )
    const lines = csv.split('\n')
    expect(lines[0]).toBe('Person,Job title,Amount,Currency,Pay basis,From,To,Days covered')
    expect(lines[1]).toBe(`"'=Ana",Clerk,1200.50,EUR,monthly,2026-09-01,2026-09-30,30`)
  })
})
