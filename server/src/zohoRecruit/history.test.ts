import { describe, expect, it } from 'vitest'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  buildHistory,
  durationMinutes,
  interviewKind,
  interviewNotes,
  noteBody,
  noteKind,
  readHistoryExport,
  recommendationOf,
  reviewSummary,
  type HistoryInterview,
  type HistoryNote,
  type HistoryReview,
} from './history.js'

const FIXTURES = path.join(path.dirname(fileURLToPath(import.meta.url)), 'fixtures', 'Data')
const TZ = 'Europe/Skopje'

const { payload, counts, problems } = buildHistory(readHistoryExport(FIXTURES), { tz: TZ })
const notesById = new Map<string, HistoryNote>(payload.candidate_notes.map((n) => [n.zoho_id, n]))
const interviewsById = new Map<string, HistoryInterview>(payload.interviews.map((i) => [i.zoho_id, i]))
const reviewsById = new Map<string, HistoryReview>(payload.reviews.map((r) => [r.zoho_id, r]))

describe('the note kind map (D2)', () => {
  it('maps every Zoho type the export holds', () => {
    expect(noteKind('Notes')).toBe('note')
    expect(noteKind('Call')).toBe('call')
    expect(noteKind('Meeting')).toBe('meeting')
    expect(noteKind('Change Status')).toBe('status_change')
    expect(noteKind('Association')).toBe('association')
    expect(noteKind('Unassociation')).toBe('unassociation')
    expect(noteKind('General Review')).toBe('review')
    expect(noteKind('TASK')).toBe('task')
    expect(noteKind('Others')).toBe('other')
  })

  it('every dated LinkedIn Msgs type is a message', () => {
    expect(noteKind('LinkedIn Msgs 2022-10-04')).toBe('message')
    expect(noteKind('LinkedIn Msgs 2024-11-12')).toBe('message')
    expect(noteKind('linkedin msgs 2022-09-26')).toBe('message')
  })

  it('anything else is other, never a guess', () => {
    expect(noteKind('Lock Record')).toBe('other')
    expect(noteKind('Unlock Record')).toBe('other')
    expect(noteKind('')).toBe('other')
  })
})

describe('the note body', () => {
  it('trims and keeps a body the CHECK allows', () => {
    expect(noteBody('  Called, no answer.  ')).toEqual({ body: 'Called, no answer.', truncated: false })
    expect(noteBody('x'.repeat(4000))).toEqual({ body: 'x'.repeat(4000), truncated: false })
  })

  it('cuts a longer body to 4,000 characters with an ellipsis', () => {
    const cut = noteBody('y'.repeat(5000))
    expect(cut.truncated).toBe(true)
    expect(cut.body).toHaveLength(4000)
    expect(cut.body.endsWith(' …')).toBe(true)
    expect(cut.body.slice(0, 3998)).toBe('y'.repeat(3998))
  })
})

describe('the notes over the fixtures (D2)', () => {
  it('counts what 052 already attached, the other modules and what is left', () => {
    expect(counts.notes).toEqual({ imported: 4, skipped_modules: 2, already_attached: 1, truncated: 0 })
  })

  it('leaves out the note whose (candidate, job) pair is an association', () => {
    // 601 is candidate 201 on job 301 — association 501, imported by 052.
    expect(notesById.has('Zrecruit_10000000000000601')).toBe(false)
  })

  it('keeps a note whose job pair is no association', () => {
    expect(notesById.get('Zrecruit_10000000000000607')).toMatchObject({
      candidate_zoho_id: 'Zrecruit_10000000000000201',
      kind: 'note',
      zoho_type: 'Notes',
    })
  })

  it('leaves out the notes of the other modules', () => {
    expect(notesById.has('Zrecruit_10000000000000603')).toBe(false)
    expect(notesById.has('Zrecruit_10000000000000605')).toBe(false)
  })

  it('takes the candidate from the parent when the note carries no candidate id', () => {
    expect(notesById.get('Zrecruit_10000000000000604')?.candidate_zoho_id).toBe('Zrecruit_10000000000000203')
  })

  it('carries the kind, the verbatim Zoho type, the actor and the stamp', () => {
    expect(notesById.get('Zrecruit_10000000000000606')).toEqual({
      zoho_id: 'Zrecruit_10000000000000606',
      candidate_zoho_id: 'Zrecruit_10000000000000202',
      kind: 'message',
      zoho_type: 'LinkedIn Msgs 2022-10-04',
      body: 'Sent a LinkedIn message about the Vue role.',
      actor_zoho_id: 'Zrecruit_10000000000000101',
      actor_name: 'Kristina Testova',
      created_at: '2022-10-04T07:15:00.000Z',
    })
  })

  it('reads the stamp as a wall clock in the export time zone', () => {
    // 19 Feb 2024 16:00 in Skopje is CET, an hour east of UTC.
    expect(notesById.get('Zrecruit_10000000000000602')).toMatchObject({
      kind: 'status_change',
      created_at: '2024-02-19T15:00:00.000Z',
    })
  })

  it('never builds the 052 prefix — import_zoho_history adds it when the actor stays unlinked', () => {
    for (const note of payload.candidate_notes) expect(note.body.startsWith('[Zoho ')).toBe(false)
  })
})

describe('the interview mapping (D3)', () => {
  it('only a "phone" name is a phone interview', () => {
    expect(interviewKind('Phone screen')).toBe('phone')
    expect(interviewKind('phone Interview')).toBe('phone')
    expect(interviewKind('Level 1 Interview')).toBe('other')
    expect(interviewKind('')).toBe('other')
  })

  it('clamps the duration to 15..480 and falls back to 60', () => {
    const from = '2022-10-05T14:30:00.000Z'
    expect(durationMinutes(from, '2022-10-05T15:30:00.000Z')).toBe(60)
    expect(durationMinutes(from, '2022-10-05T14:35:00.000Z')).toBe(15)
    expect(durationMinutes(from, '2022-10-06T14:30:00.000Z')).toBe(480)
    expect(durationMinutes(from, from)).toBe(60)
    expect(durationMinutes(from, '2022-10-05T13:30:00.000Z')).toBe(60)
    expect(durationMinutes(null, '2022-10-05T15:30:00.000Z')).toBe(60)
    expect(durationMinutes(from, null)).toBe(60)
  })

  it('joins the two free-text fields, or neither', () => {
    expect(interviewNotes('Strong.', 'Bring the portfolio.')).toBe('Feedback: Strong.\n\nSchedule comments: Bring the portfolio.')
    expect(interviewNotes('Strong.', null)).toBe('Feedback: Strong.')
    expect(interviewNotes(null, 'Bring it.')).toBe('Schedule comments: Bring it.')
    expect(interviewNotes(null, null)).toBeNull()
  })

  it('reads From and To as wall clocks in the export time zone', () => {
    expect(interviewsById.get('Zrecruit_10000000000000702')).toMatchObject({
      kind: 'phone',
      scheduled_at: '2022-10-05T14:30:00.000Z',
      duration_minutes: 60,
      status: 'completed',
      outcome: 'Move to next round',
      notes: 'Feedback: Strong on the basics.\n\nSchedule comments: Bring the portfolio.',
      owner_zoho_id: 'Zrecruit_10000000000000101',
      interviewer_zoho_ids: ['Zrecruit_10000000000000101'],
      location: null,
      cancellation_reason: null,
    })
  })

  it('a cancelled interview keeps its reason and its verbatim outcome, and the 5-minute span is clamped', () => {
    expect(interviewsById.get('Zrecruit_10000000000000703')).toMatchObject({
      kind: 'other',
      name: 'Level 1 Interview',
      scheduled_at: '2023-03-26T11:00:00.000Z',
      duration_minutes: 15,
      status: 'cancelled',
      outcome: 'Cancelled',
      location: 'Skopje office',
      cancellation_reason: 'Candidate withdrew.',
      notes: null,
    })
  })

  it('splits the interviewers on both separators', () => {
    expect(interviewsById.get('Zrecruit_10000000000000703')?.interviewer_zoho_ids).toEqual([
      'Zrecruit_10000000000000101',
      'Zrecruit_10000000000000102',
      'Zrecruit_10000000000000103',
    ])
  })

  it('a long span is clamped to 480 and a blank status is no outcome', () => {
    expect(interviewsById.get('Zrecruit_10000000000000704')).toMatchObject({
      duration_minutes: 480,
      status: 'completed',
      outcome: null,
    })
  })

  it('a missing From is no stamp and the default hour', () => {
    expect(interviewsById.get('Zrecruit_10000000000000701')).toMatchObject({
      scheduled_at: null,
      duration_minutes: 60,
      interviewer_zoho_ids: [],
      owner_zoho_id: null,
    })
  })

  it('keeps every interview and counts the matched pairs', () => {
    expect(payload.interviews).toHaveLength(4)
    expect(counts.interviews).toEqual({ matched: 3, unmatched: 1 })
  })
})

describe('the review mapping (D4)', () => {
  it('maps the 1..4 rating to a recommendation', () => {
    expect(recommendationOf(4)).toBe('strong_yes')
    expect(recommendationOf(3)).toBe('yes')
    expect(recommendationOf(2)).toBe('no')
    expect(recommendationOf(1)).toBe('strong_no')
  })

  it('builds the summary from the comments and the assessment answers', () => {
    expect(reviewSummary('Good.', [{ question: 'Q1', answer: 'A1' }])).toBe('Good.\n\nQ: Q1 — A: A1')
    expect(reviewSummary(null, [{ question: 'Q1', answer: 'A1' }])).toBe('Q: Q1 — A: A1')
    expect(reviewSummary('Good.', [])).toBe('Good.')
    expect(reviewSummary(null, [])).toBeNull()
  })

  it('carries the rating, the recommendation, the source and the assessment question/answer lines', () => {
    expect(reviewsById.get('Zrecruit_10000000000000801')).toEqual({
      zoho_id: 'Zrecruit_10000000000000801',
      interview_zoho_id: 'Zrecruit_10000000000000702',
      rating: 4,
      recommendation: 'strong_yes',
      comments: 'Strong on Vue, and on the basics.',
      summary:
        'Strong on Vue, and on the basics.\n\nQ: How did they handle state management? — A: Explained Pinia well.\nQ: Would you work with them? — A: Yes.',
      source: 'Interviewer Review',
      author_zoho_id: 'Zrecruit_10000000000000101',
      created_at: '2022-10-06T09:42:00.000Z',
    })
  })

  it('a review with no comments and no answered question has no summary', () => {
    expect(reviewsById.get('Zrecruit_10000000000000802')).toMatchObject({
      rating: 3,
      recommendation: 'yes',
      comments: null,
      summary: null,
    })
  })

  it('a rating outside 1..4 is a problem and the row stays out', () => {
    expect(reviewsById.has('Zrecruit_10000000000000804')).toBe(false)
    expect(problems).toEqual([{ kind: 'review', ref: 'Zrecruit_10000000000000804', message: 'Rating "5.0" is not 1..4' }])
    expect(counts.problems).toBe(1)
  })

  it('counts the matched interview, the unmatched one and the second review by the same author', () => {
    expect(payload.reviews).toHaveLength(4)
    expect(counts.reviews).toEqual({ matched: 3, unmatched: 1, duplicates: 1 })
  })
})

describe('the payload', () => {
  it('holds exactly the four keys import_zoho_history reads', () => {
    expect(Object.keys(payload).sort()).toEqual(['candidate_notes', 'interviews', 'reviews', 'users'])
  })

  it('carries the users the import resolves to people', () => {
    expect(counts.users).toBe(2)
    expect(payload.users[0]).toEqual({ zoho_id: 'Zrecruit_10000000000000101', email: 'recruiter@example.test', name: 'Kristina Testova' })
  })
})
