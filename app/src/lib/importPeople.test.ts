import { describe, expect, it } from 'vitest'
import { parseCsv, shapeRows, IMPORT_TEMPLATE } from './importPeople'

describe('parseCsv', () => {
  it('handles quoted fields, embedded commas and CRLF', () => {
    const rows = parseCsv('name,note\r\n"Doe, Jane","said ""hi"""\r\nBob,plain\r\n')
    expect(rows).toEqual([
      ['name', 'note'],
      ['Doe, Jane', 'said "hi"'],
      ['Bob', 'plain'],
    ])
  })
  it('skips blank lines', () => {
    expect(parseCsv('a,b\n\n1,2\n')).toEqual([['a', 'b'], ['1', '2']])
  })
})

describe('shapeRows', () => {
  it('maps headers case-insensitively with aliases and reports unknown required columns', () => {
    const shaped = shapeRows([
      ['Full Name', 'Email', 'Job Title', 'Start', 'Manager email', 'Department'],
      ['Ana Ilic', 'ana@x.test', 'Clerk', '2026-01-10', 'boss@x.test', 'Ops'],
    ])
    expect(shaped.missing).toEqual([])
    expect(shaped.rows).toEqual([
      { full_name: 'Ana Ilic', work_email: 'ana@x.test', job_title: 'Clerk', start_date: '2026-01-10', manager_email: 'boss@x.test', department: 'Ops' },
    ])
  })
  it('names the required columns that are absent', () => {
    const shaped = shapeRows([['name', 'title'], ['Ana', 'Clerk']])
    expect(shaped.missing).toEqual(['work_email', 'start_date'])
  })
  it('converts common date formats to ISO', () => {
    const shaped = shapeRows([['full_name', 'work_email', 'job_title', 'start_date'], ['A B', 'a@x.test', 'C', '25/01/2026']])
    expect(shaped.rows[0]?.start_date).toBe('2026-01-25')
  })
  it('ships a template with the accepted headers', () => {
    expect(IMPORT_TEMPLATE.split('\n')[0]).toBe(
      'full_name,work_email,job_title,start_date,employment_type_key,department,location,manager_email,preferred_name,phone,personal_email,birth_date,address,national_id,bank_name,bank_account_number,emergency_contact_name,emergency_contact_relationship,emergency_contact_phone,salary_amount,salary_currency,salary_basis',
    )
  })
  it('maps the personal, bank and salary columns and converts the birth date', () => {
    const shaped = shapeRows([
      ['full_name', 'work_email', 'job_title', 'start_date', 'Date of birth', 'EMBG', 'IBAN', 'Bank', 'Emergency contact', 'Relationship', 'Emergency phone', 'Salary', 'Currency', 'Pay basis', 'Personal email', 'Address'],
      ['Ana Ilic', 'ana@x.test', 'Clerk', '2026-01-10', '17.05.1990', '1705990450001', 'MK07300', 'NLB', 'Petar', 'brother', '070', '1500', 'EUR', 'monthly', 'ana@gmail.com', 'Partizanska 1'],
    ])
    expect(shaped.ignored).toEqual([])
    expect(shaped.rows[0]).toMatchObject({
      birth_date: '1990-05-17',
      national_id: '1705990450001',
      bank_account_number: 'MK07300',
      bank_name: 'NLB',
      emergency_contact_name: 'Petar',
      emergency_contact_relationship: 'brother',
      emergency_contact_phone: '070',
      salary_amount: '1500',
      salary_currency: 'EUR',
      salary_basis: 'monthly',
      personal_email: 'ana@gmail.com',
      address: 'Partizanska 1',
    })
  })
})

describe('delimiters and ambiguous dates', () => {
  it('accepts semicolon-separated files (EU Excel)', () => {
    expect(parseCsv('a;b\n1;"x;y"\n')).toEqual([['a', 'b'], ['1', 'x;y']])
  })
  it('passes an ambiguous d/m vs m/d date through untouched so the database refuses it', () => {
    const shaped = shapeRows([['full_name', 'work_email', 'job_title', 'start_date'], ['A B', 'a@x.test', 'C', '03/04/2026']])
    expect(shaped.rows[0]?.start_date).toBe('03/04/2026')
    const unambiguous = shapeRows([['full_name', 'work_email', 'job_title', 'start_date'], ['A B', 'a@x.test', 'C', '25.04.2026']])
    expect(unambiguous.rows[0]?.start_date).toBe('2026-04-25')
  })
})
