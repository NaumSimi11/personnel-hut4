import { describe, expect, it } from 'vitest'
import { renderWelcomeNote } from './welcomeNote.js'

describe('renderWelcomeNote', () => {
  it('renders the note as a PDF with its lines', async () => {
    const pdf = await renderWelcomeNote({
      company: 'Snowball',
      subject: 'Welcome to Snowball, Ана',
      lines: ['Dear Ана,', '', 'Welcome to Snowball. We are glad you are joining us as Analyst, starting on 01 October 2026.', '', 'Your first day', 'Where: Reception', '', 'Our policies', '• Code of Conduct — How we treat each other', '', 'See you soon,', 'HR, Snowball'],
    })
    expect(pdf.subarray(0, 5).toString()).toBe('%PDF-')
    expect(pdf.length).toBeGreaterThan(1500)
  })
})
