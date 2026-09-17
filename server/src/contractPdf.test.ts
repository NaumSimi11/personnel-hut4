import { describe, expect, it } from 'vitest'
import { renderContract } from './contractPdf.js'

describe('renderContract', () => {
  const data = {
    title: 'Employment agreement',
    companyName: 'Synami',
    personName: 'Naum Simidjioski',
    body: 'This agreement is made on 2026-09-17.\n\nThe employee is engaged as Software Developer.',
    issuedOn: '2026-09-17',
    version: 2,
  }

  it('renders a real PDF', async () => {
    const pdf = await renderContract(data)
    expect(pdf.length).toBeGreaterThan(900)
    expect(pdf.subarray(0, 5).toString()).toBe('%PDF-')
  })

  it('survives a body that is only one paragraph', async () => {
    const pdf = await renderContract({ ...data, body: 'A single clause and nothing else.' })
    expect(pdf.subarray(0, 5).toString()).toBe('%PDF-')
  })

  it('survives an empty body rather than throwing', async () => {
    // An empty contract is wrong, but the caller decides that — a renderer that
    // throws here would take out the whole queue over one bad template.
    const pdf = await renderContract({ ...data, body: '' })
    expect(pdf.subarray(0, 5).toString()).toBe('%PDF-')
  })
})
