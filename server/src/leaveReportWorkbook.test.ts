import { describe, expect, it } from 'vitest'
import { buildLeaveReport, leaveReportSheets } from './leaveReport.js'
import { RECORD_COLUMNS, SUMMARY_COLUMNS, type ReportPerson, type ReportRequest } from '../../shared/leaveReport.js'

const requests: ReportRequest[] = [
  {
    reference: '1042',
    person_id: 'p2',
    person_name: 'Zoran Petrov',
    company_id: 'c1',
    company_name: 'Hut4',
    country_code: 'MK',
    leave_type: 'Annual leave',
    start_date: '2026-09-14',
    end_date: '2026-09-18',
    working_days: 5,
    status: 'approved',
    deducts_balance: true,
  },
  {
    reference: '1041',
    person_id: 'p1',
    person_name: 'Ana Ilievska',
    company_id: 'c1',
    company_name: 'Hut4',
    country_code: 'MK',
    leave_type: 'Sick leave',
    start_date: '2026-09-01',
    end_date: '2026-09-02',
    working_days: 2,
    status: 'approved',
    deducts_balance: false,
  },
]

const people: ReportPerson[] = [
  {
    person_name: 'Ana Ilievska',
    company_name: 'Hut4',
    country_code: 'MK',
    employment_status: 'active',
    entitlement: 22,
    approved_days: 4,
    remaining: 18,
    carry_over_remaining: 3,
    has_balance: true,
  },
  {
    person_name: 'Bea Novak',
    company_name: 'Praedium',
    country_code: 'RS',
    employment_status: 'former',
    entitlement: 0,
    approved_days: 0,
    remaining: 0,
    carry_over_remaining: 0,
    has_balance: false,
  },
]

describe('leaveReportSheets', () => {
  const [records, summary] = leaveReportSheets({ requests, people })

  it('is the two sheets finance asks for, named as Field Notebook names them', () => {
    expect(records.name).toBe('Leave records')
    expect(summary.name).toBe('Balance summary')
  })

  it('carries the same headers, in the same order', () => {
    expect(records.columns.map((c) => c.header)).toEqual([...RECORD_COLUMNS])
    expect(summary.columns.map((c) => c.header)).toEqual([...SUMMARY_COLUMNS])
  })

  it('writes the dates as dates and the day counts as numbers', () => {
    expect(records.columns[4].kind).toBe('date')
    expect(records.columns[5].kind).toBe('date')
    expect(records.columns[7].kind).toBe('number')
    // The ledger columns are numbers too, so a column of days can be summed;
    // the writer falls back to text for the "Not applicable" rows.
    expect(summary.columns[7].kind).toBe('number')
    expect(summary.columns[8].kind).toBe('number')
  })

  it('puts the oldest request first, whatever order it arrived in', () => {
    expect(records.rows.map((r) => r[0])).toEqual(['1041', '1042'])
  })

  it('spells out what each request did to the balance', () => {
    expect(records.rows[0][9]).toBe('No annual leave deduction')
    expect(records.rows[1][9]).toBe('Deducts 5 annual leave days')
  })

  it('sorts the summary by company then name, and says "Not applicable" where there is no ledger', () => {
    expect(summary.rows.map((r) => r[0])).toEqual(['Ana Ilievska', 'Bea Novak'])
    expect(summary.rows[0][7]).toBe(3)
    expect(summary.rows[1][7]).toBe('Not applicable')
    expect(summary.rows[1][3]).toBe('Former')
  })
})

describe('buildLeaveReport', () => {
  it('returns a workbook, and an empty view still makes a readable one', () => {
    const bytes = buildLeaveReport({ requests, people })
    expect(bytes.subarray(0, 2).toString()).toBe('PK')
    expect(bytes.length).toBeGreaterThan(1000)

    const empty = buildLeaveReport({ requests: [], people: [] })
    expect(empty.subarray(0, 2).toString()).toBe('PK')
  })
})
