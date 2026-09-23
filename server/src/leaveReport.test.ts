import { describe, expect, it } from 'vitest'
import {
  balanceEffect,
  countryName,
  describeRecordFilter,
  employmentLabel,
  EMPTY_RECORD_FILTER,
  foldText,
  isRecordFilterActive,
  leaveReportFilename,
  matchesRecordFilter,
  monthsCovered,
  NOT_APPLICABLE,
  recordRow,
  reportYear,
  sortPeople,
  sortRequests,
  summaryRow,
  type ReportPerson,
  type ReportRequest,
} from '../../shared/leaveReport.js'

const request = (over: Partial<ReportRequest> = {}): ReportRequest => ({
  reference: '1042',
  person_id: 'p1',
  person_name: 'Ana Ilievska',
  company_id: 'c1',
  company_name: 'Hut4',
  country_code: 'MK',
  leave_type: 'Annual leave',
  start_date: '2026-09-01',
  end_date: '2026-09-04',
  working_days: 4,
  status: 'approved',
  deducts_balance: true,
  ...over,
})

const person = (over: Partial<ReportPerson> = {}): ReportPerson => ({
  person_name: 'Ana Ilievska',
  company_name: 'Hut4',
  country_code: 'MK',
  employment_status: 'active',
  entitlement: 22,
  approved_days: 4,
  remaining: 18,
  carry_over_remaining: 3,
  has_balance: true,
  ...over,
})

describe('monthsCovered', () => {
  it('lists every month a request touches, so a boundary is not missed', () => {
    expect(monthsCovered('2026-08-31', '2026-09-02')).toEqual(['2026-08', '2026-09'])
    expect(monthsCovered('2026-12-28', '2027-01-04')).toEqual(['2026-12', '2027-01'])
    expect(monthsCovered('2026-09-01', '2026-09-04')).toEqual(['2026-09'])
  })
})

describe('matchesRecordFilter', () => {
  it('passes everything through an untouched filter', () => {
    expect(matchesRecordFilter(request(), EMPTY_RECORD_FILTER)).toBe(true)
    expect(isRecordFilterActive(EMPTY_RECORD_FILTER)).toBe(false)
  })

  it('matches a month the request only touches', () => {
    const spanning = request({ start_date: '2026-08-31', end_date: '2026-09-02' })
    expect(matchesRecordFilter(spanning, { ...EMPTY_RECORD_FILTER, month: '2026-08' })).toBe(true)
    expect(matchesRecordFilter(spanning, { ...EMPTY_RECORD_FILTER, month: '2026-09' })).toBe(true)
    expect(matchesRecordFilter(spanning, { ...EMPTY_RECORD_FILTER, month: '2026-10' })).toBe(false)
  })

  it('filters by company id, not by the name shown', () => {
    expect(matchesRecordFilter(request(), { ...EMPTY_RECORD_FILTER, company: 'c1' })).toBe(true)
    expect(matchesRecordFilter(request(), { ...EMPTY_RECORD_FILTER, company: 'c2' })).toBe(false)
  })

  it('searches name, company and leave type, every word, folded', () => {
    const r = request({ person_name: 'Ana Ilievšká' })
    expect(matchesRecordFilter(r, { ...EMPTY_RECORD_FILTER, query: 'ilievska' })).toBe(true)
    expect(matchesRecordFilter(r, { ...EMPTY_RECORD_FILTER, query: 'ana annual' })).toBe(true)
    expect(matchesRecordFilter(r, { ...EMPTY_RECORD_FILTER, query: 'ana sick' })).toBe(false)
    expect(foldText('Ivanovški')).toBe('ivanovski')
  })
})

describe('describeRecordFilter / leaveReportFilename', () => {
  it('names the scope in the file, and says nothing when nothing is narrowed', () => {
    expect(describeRecordFilter(EMPTY_RECORD_FILTER)).toBe('')
    expect(leaveReportFilename('2026-09-23')).toBe('leave-finance-export-2026-09-23.xlsx')
  })

  it('carries the month, the company and the search', () => {
    const scope = describeRecordFilter({ month: '2026-09', company: 'c1', query: 'Ana Ilievska' }, 'Hut 4 Ltd')
    expect(scope).toBe('2026-09-hut-4-ltd-ana-ilievska')
    expect(leaveReportFilename('2026-09-23', scope)).toBe('leave-finance-export-2026-09-hut-4-ltd-ana-ilievska-2026-09-23.xlsx')
  })

  it('leaves the company out when its name is not known', () => {
    expect(describeRecordFilter({ month: 'all', company: 'c1', query: '' })).toBe('')
  })
})

describe('reportYear', () => {
  it('follows the filtered month, and otherwise today', () => {
    expect(reportYear({ ...EMPTY_RECORD_FILTER, month: '2025-12' }, '2026-09-23')).toBe(2025)
    expect(reportYear(EMPTY_RECORD_FILTER, '2026-09-23')).toBe(2026)
  })
})

describe('balanceEffect', () => {
  it('spells out the charge, in the singular when it is one day', () => {
    expect(balanceEffect(request())).toBe('Deducts 4 annual leave days')
    expect(balanceEffect(request({ working_days: 1 }))).toBe('Deducts 1 annual leave day')
  })

  it('reads the request’s own snapshot, not the leave type of today', () => {
    expect(balanceEffect(request({ deducts_balance: false }))).toBe('No annual leave deduction')
  })

  it('says what a cancelled or pending request did', () => {
    expect(balanceEffect(request({ status: 'cancelled' }))).toBe('Cancelled — 4 days returned')
    expect(balanceEffect(request({ status: 'cancelled', working_days: 1 }))).toBe('Cancelled — 1 day returned')
    expect(balanceEffect(request({ status: 'pending' }))).toBe('No deduction until approved')
  })
})

describe('countryName / employmentLabel', () => {
  it('names the three the holding works in and prints anything else as it is', () => {
    expect(countryName('MK')).toBe('North Macedonia')
    expect(countryName('RS')).toBe('Serbia')
    expect(countryName('MT')).toBe('Malta')
    expect(countryName('DE')).toBe('DE')
    expect(countryName(null)).toBe('—')
  })

  it('uses this app’s word for somebody who has left', () => {
    expect(employmentLabel('active')).toBe('Active')
    expect(employmentLabel('former')).toBe('Former')
  })
})

describe('recordRow', () => {
  it('lays the columns out in the order the sheet declares', () => {
    expect(recordRow(request())).toEqual([
      '1042',
      'Ana Ilievska',
      'Hut4',
      'North Macedonia',
      '2026-09-01',
      '2026-09-04',
      'Annual leave',
      4,
      'approved',
      'Deducts 4 annual leave days',
    ])
  })
})

describe('summaryRow', () => {
  it('adds the carry-over into what is left to take', () => {
    expect(summaryRow(person())).toEqual(['Ana Ilievska', 'Hut4', 'North Macedonia', 'Active', 22, 4, 21, 3, 18])
  })

  it('says "not applicable" rather than a zero finance would misread', () => {
    const row = summaryRow(person({ has_balance: false, entitlement: 0, remaining: 0, carry_over_remaining: 0 }))
    expect(row[7]).toBe(NOT_APPLICABLE)
    expect(row[8]).toBe(NOT_APPLICABLE)
  })
})

describe('sorting', () => {
  it('puts requests oldest first, then by name', () => {
    const rows = [
      request({ reference: 'b', start_date: '2026-09-02' }),
      request({ reference: 'c', start_date: '2026-09-01', person_name: 'Zoran' }),
      request({ reference: 'a', start_date: '2026-09-01', person_name: 'Ana' }),
    ]
    expect(sortRequests(rows).map((r) => r.reference)).toEqual(['a', 'c', 'b'])
  })

  it('puts people by company, then by name', () => {
    const rows = [person({ company_name: 'Praedium' }), person({ company_name: 'Hut4', person_name: 'Zoran' }), person({ company_name: 'Hut4', person_name: 'Ana' })]
    expect(sortPeople(rows).map((p) => `${p.company_name}/${p.person_name}`)).toEqual([
      'Hut4/Ana',
      'Hut4/Zoran',
      'Praedium/Ana Ilievska',
    ])
  })
})
