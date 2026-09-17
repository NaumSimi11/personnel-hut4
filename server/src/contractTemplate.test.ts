import { describe, expect, it } from 'vitest'
import {
  TEMPLATE_FIELDS,
  canIssue,
  labelFor,
  placeholdersIn,
  renderTemplate,
} from '../../shared/contractTemplate.js'

const PERSON = {
  full_name: 'Naum Simidjioski',
  job_title: 'Software Developer',
  company: 'Synami',
  start_date: '2026-01-01',
  salary: '60000',
  currency: 'MKD',
  today: '2026-09-17',
}

describe('placeholdersIn', () => {
  it('finds each placeholder once, in the order used', () => {
    expect(placeholdersIn('{{full_name}} works at {{company}} as {{job_title}}, {{company}}.'))
      .toEqual(['full_name', 'company', 'job_title'])
  })

  it('tolerates spacing inside the braces', () => {
    expect(placeholdersIn('{{ full_name }} and {{job_title  }}')).toEqual(['full_name', 'job_title'])
  })

  it('finds none in a body that has none', () => {
    expect(placeholdersIn('A contract with no fields at all.')).toEqual([])
  })
})

describe('renderTemplate', () => {
  it('puts the values in', () => {
    const out = renderTemplate('{{full_name}}, {{job_title}} at {{company}} from {{start_date}}.', PERSON)
    expect(out.text).toBe('Naum Simidjioski, Software Developer at Synami from 2026-01-01.')
    expect(canIssue(out)).toBe(true)
  })

  it('names a required field the person has no value for, and will not issue', () => {
    const out = renderTemplate('{{full_name}} starts on {{start_date}}.', { full_name: 'Ana', start_date: '' })
    expect(out.missing).toEqual(['start_date'])
    expect(canIssue(out)).toBe(false)
  })

  it('leaves a missing value visible rather than blank', () => {
    // "a monthly salary of  MKD" is what a silent blank produces, and nobody
    // reads a contract twice. A visible {{salary}} is caught by anyone.
    const out = renderTemplate('A monthly salary of {{salary}} {{currency}}.', { ...PERSON, salary: '' })
    expect(out.text).toBe('A monthly salary of {{salary}} MKD.')
  })

  it('does not block on an optional field the person lacks', () => {
    const out = renderTemplate('{{full_name}} reports to {{manager}}.', { ...PERSON, manager: '' })
    expect(out.missing).toEqual([])
    expect(canIssue(out)).toBe(true)
  })

  it('reports a placeholder no field defines, and refuses to issue', () => {
    // Almost always a typo — {{salery}} would otherwise print itself into a
    // signed contract.
    const out = renderTemplate('Pay: {{salery}}.', PERSON)
    expect(out.unknown).toEqual(['salery'])
    expect(canIssue(out)).toBe(false)
  })

  it('reports each missing field once however often it is used', () => {
    const out = renderTemplate('{{start_date}} … {{start_date}} … {{start_date}}', { start_date: '' })
    expect(out.missing).toEqual(['start_date'])
  })

  it('treats whitespace as no value', () => {
    expect(renderTemplate('{{job_title}}', { job_title: '   ' }).missing).toEqual(['job_title'])
  })

  it('leaves text with no placeholders exactly as it was', () => {
    const body = 'This agreement is made between the parties.'
    expect(renderTemplate(body, PERSON).text).toBe(body)
  })
})

describe('TEMPLATE_FIELDS', () => {
  it('requires the facts a contract cannot be signed without', () => {
    const required = TEMPLATE_FIELDS.filter((f) => f.required).map((f) => f.key)
    expect(required).toEqual(['full_name', 'job_title', 'company', 'start_date', 'today'])
  })

  it('has a label for every field, so the editor can list them', () => {
    for (const f of TEMPLATE_FIELDS) expect(f.label.length).toBeGreaterThan(2)
    expect(labelFor('salary')).toBe('Salary')
    expect(labelFor('nonsense')).toBe('nonsense')
  })
})
