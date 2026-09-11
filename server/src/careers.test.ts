import { describe, expect, it } from 'vitest'
import {
  HONEYPOT_FIELD,
  RateLimiter,
  applicationInput,
  checkAnswers,
  isDuplicateApplication,
  isShortCode,
  isHoneypotTripped,
  publicBrief,
  publicCompany,
  referenceFor,
  validateCv,
} from './careers.js'

describe('RateLimiter', () => {
  it('allows up to the limit inside the window, then refuses until it slides', () => {
    let now = 1_000_000
    const limiter = new RateLimiter({ max: 3, windowMs: 60_000, now: () => now })
    expect(limiter.allow('ip:1')).toBe(true)
    expect(limiter.allow('ip:1')).toBe(true)
    expect(limiter.allow('ip:1')).toBe(true)
    expect(limiter.allow('ip:1')).toBe(false)
    expect(limiter.allow('ip:2')).toBe(true) // independent keys
    now += 60_001
    expect(limiter.allow('ip:1')).toBe(true)
  })
})

describe('applicationInput', () => {
  const good = {
    name: '  Jamie Taylor ',
    email: 'Jamie@Example.test',
    phone: '',
    answers: JSON.stringify([{ question_id: 'q1', answer: ' yes ' }]),
    consent: 'true',
  }

  it('normalises name and email and parses the answers JSON', () => {
    const parsed = applicationInput.safeParse(good)
    expect(parsed.success).toBe(true)
    if (parsed.success) {
      expect(parsed.data.name).toBe('Jamie Taylor')
      expect(parsed.data.email).toBe('jamie@example.test')
      expect(parsed.data.answers).toEqual([{ question_id: 'q1', answer: 'yes' }])
      expect(parsed.data.consent).toBe(true)
    }
  })

  it('requires consent, a valid email and a name', () => {
    expect(applicationInput.safeParse({ ...good, consent: 'false' }).success).toBe(false)
    expect(applicationInput.safeParse({ ...good, email: 'nope' }).success).toBe(false)
    expect(applicationInput.safeParse({ ...good, name: 'J' }).success).toBe(false)
  })

  it('treats missing or malformed answers as none', () => {
    const parsed = applicationInput.safeParse({ ...good, answers: 'not json' })
    expect(parsed.success).toBe(true)
    if (parsed.success) expect(parsed.data.answers).toEqual([])
  })
})

describe('isHoneypotTripped', () => {
  it('trips when the hidden field carries anything, and is not named like an autofill target', () => {
    expect(HONEYPOT_FIELD).not.toMatch(/website|url|phone|email|name|address/i)
    expect(isHoneypotTripped({ [HONEYPOT_FIELD]: '' })).toBe(false)
    expect(isHoneypotTripped({})).toBe(false)
    expect(isHoneypotTripped({ [HONEYPOT_FIELD]: 'http://spam.example' })).toBe(true)
  })
})

describe('validateCv', () => {
  it('accepts PDF and Word up to 10 MB, refuses the rest', () => {
    expect(validateCv({ mimetype: 'application/pdf', size: 10 * 1024 * 1024, filename: 'cv.pdf' })).toBeNull()
    expect(validateCv({ mimetype: 'image/png', size: 10, filename: 'cv.png' })).toBe(
      'Attach your CV as a PDF or Word document.',
    )
    expect(validateCv({ mimetype: 'application/pdf', size: 10 * 1024 * 1024 + 1, filename: 'cv.pdf' })).toBe(
      'Your CV must be 10 MB or smaller.',
    )
  })
})

describe('publicCompany / publicBrief', () => {
  const company = {
    id: 'c1',
    name: 'Snowball',
    short_code: 'SNOW',
    website: 'https://snowball.example',
    brand: { logo_path: 'c1/logo-1.png', accent_color: '#3e744e', tagline: 'Snow for everyone', secret: 'x' },
  }

  it('exposes only public brand facts, with the logo as a public URL', () => {
    const out = publicCompany(company, 'https://proj.supabase.co')
    expect(out).toEqual({
      name: 'Snowball',
      code: 'SNOW',
      website: 'https://snowball.example',
      tagline: 'Snow for everyone',
      accentColor: '#3e744e',
      logoUrl: 'https://proj.supabase.co/storage/v1/object/public/company-logos/c1/logo-1.png',
    })
  })

  it('strips internal job fields and keeps only the question shape candidates need', () => {
    const out = publicBrief({
      id: 'j1',
      title: 'Coordinator',
      description: 'Own the schedule.',
      screening_questions: [
        { id: 'q1', prompt: 'Why?', kind: 'text', required: true, internalNote: 'x' },
        { id: 'q2', prompt: 'Notice', kind: 'choice', required: false, options: ['Now', '1 month'] },
      ],
      scorecard_criteria: [{ id: 'x', label: 'secret' }],
      status: 'open',
    })
    expect(out).toEqual({
      id: 'j1',
      title: 'Coordinator',
      description: 'Own the schedule.',
      questions: [
        { id: 'q1', prompt: 'Why?', kind: 'text', required: true },
        { id: 'q2', prompt: 'Notice', kind: 'choice', required: false, options: ['Now', '1 month'] },
      ],
    })
  })
})

describe('isDuplicateApplication', () => {
  it('is true only for a non-terminal application to the same job', () => {
    expect(isDuplicateApplication([{ stage_key: 'new' }])).toBe(true)
    expect(isDuplicateApplication([{ stage_key: 'rejected' }, { stage_key: 'withdrawn' }])).toBe(false)
    expect(isDuplicateApplication([])).toBe(false)
  })
})

describe('referenceFor', () => {
  it('is a short, upper-case, unambiguous token from the application id', () => {
    expect(referenceFor('9a1b2c3d-0000-4000-8000-000000000000')).toBe('9A1B2C3D')
  })
})

describe('RateLimiter eviction', () => {
  it('forgets keys whose attempts have all expired, so memory is bounded', () => {
    let now = 0
    const limiter = new RateLimiter({ max: 2, windowMs: 1000, now: () => now })
    for (let i = 0; i < 50; i++) limiter.allow(`email:${i}`)
    expect(limiter.size).toBe(50)
    now += 1001
    limiter.allow('email:new')
    expect(limiter.size).toBe(1)
  })
})

describe('checkAnswers', () => {
  const questions = [
    { id: 'q-why', prompt: 'Why?', kind: 'text', required: true },
    { id: 'q-eligible', prompt: 'Eligible?', kind: 'yes_no', required: true },
    { id: 'q-notice', prompt: 'Notice', kind: 'choice', required: false, options: ['Now', '1 month'] },
  ]

  it('accepts complete, well-formed answers and drops unknown questions', () => {
    const out = checkAnswers(questions, [
      { question_id: 'q-why', answer: 'Growth' },
      { question_id: 'q-eligible', answer: 'yes' },
      { question_id: 'q-notice', answer: '1 month' },
      { question_id: 'q-ghost', answer: 'x' },
    ])
    expect(out).toEqual({
      ok: true,
      answers: [
        { question_id: 'q-why', answer: 'Growth' },
        { question_id: 'q-eligible', answer: 'yes' },
        { question_id: 'q-notice', answer: '1 month' },
      ],
    })
  })

  it('refuses a missing required answer, naming the question', () => {
    expect(checkAnswers(questions, [{ question_id: 'q-why', answer: 'Growth' }])).toEqual({
      ok: false,
      error: 'Please answer: Eligible?',
    })
  })

  it('refuses answers outside the allowed values', () => {
    expect(
      checkAnswers(questions, [
        { question_id: 'q-why', answer: 'Growth' },
        { question_id: 'q-eligible', answer: 'maybe' },
      ]),
    ).toEqual({ ok: false, error: 'Please answer: Eligible?' })
    expect(
      checkAnswers(questions, [
        { question_id: 'q-why', answer: 'Growth' },
        { question_id: 'q-eligible', answer: 'no' },
        { question_id: 'q-notice', answer: 'Never' },
      ]),
    ).toEqual({ ok: false, error: 'Choose one of the options for: Notice' })
  })
})

describe('isShortCode', () => {
  it('accepts 2–6 letters or digits only — no wildcards', () => {
    expect(isShortCode('snow')).toBe(true)
    expect(isShortCode('A1')).toBe(true)
    expect(isShortCode('a%')).toBe(false)
    expect(isShortCode('AB_')).toBe(false)
    expect(isShortCode('TOOLONGX')).toBe(false)
  })
})
