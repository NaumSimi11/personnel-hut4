import { describe, expect, it } from 'vitest'
import {
  EVENTS,
  canPlaceField,
  eventLabel,
  light,
  recipientSummary,
  recipientTarget,
  sendLine,
  type HandoverFieldDef,
  type HandoverSend,
} from './handover'

const fields: HandoverFieldDef[] = [
  { key: 'name', label: 'Full name', sensitivity: 'plain' },
  { key: 'national_id', label: 'National ID number', sensitivity: 'personal' },
  { key: 'salary', label: 'Salary', sensitivity: 'pay' },
]

const send = (over: Partial<HandoverSend>): HandoverSend => ({
  id: 's',
  event: 'hire_confirmed',
  recipient_label: 'Accountant',
  to_email: 'books@x.test',
  fields: {},
  stripped: [],
  missing: [],
  status: 'pending',
  error: null,
  sent_at: null,
  marked_by: null,
  ...over,
})

describe('traffic light', () => {
  it('is green for sent and manual, red for failed and missing, grey otherwise', () => {
    expect(light('sent')).toBe('green')
    expect(light('manual')).toBe('green')
    expect(light('failed')).toBe('red')
    expect(light('missing')).toBe('red')
    expect(light('pending')).toBe('grey')
    expect(light('cancelled')).toBe('grey')
  })
  it('says what happened in one line, naming the missing fields', () => {
    expect(sendLine(send({ status: 'missing', missing: ['Bank account', 'Address for Accountant'] }))).toBe('Not sent — missing Bank account, Address for Accountant')
    expect(sendLine(send({ status: 'sent', sent_at: '2026-09-16T10:00:00Z' }))).toBe('Sent 16 Sep 2026')
    expect(sendLine(send({ status: 'manual', sent_at: '2026-09-16T10:00:00Z' }))).toBe('Sent by hand 16 Sep 2026')
    expect(sendLine(send({ status: 'failed', error: 'Resend responded 500' }))).toBe('Failed — Resend responded 500')
    expect(sendLine(send({ status: 'pending' }))).toBe('Queued for sending')
    expect(sendLine(send({ status: 'cancelled' }))).toBe('Cancelled with the departure')
  })
})

describe('recipient settings', () => {
  it('lets a sensitive field be placed only on a trusted recipient by someone who may see it', () => {
    const viewer = { can: (_c: string, cap: string) => cap === 'personal.view' }
    expect(canPlaceField(fields[0]!, { trusted: false }, viewer, 'c1')).toBe(true)
    expect(canPlaceField(fields[1]!, { trusted: false }, viewer, 'c1')).toBe(false)
    expect(canPlaceField(fields[1]!, { trusted: true }, viewer, 'c1')).toBe(true)
    expect(canPlaceField(fields[2]!, { trusted: true }, viewer, 'c1')).toBe(false)
  })
  it('describes who a recipient is and what they get', () => {
    expect(recipientTarget({ kind: 'role', role_key: 'it_owner', person_id: null, email: null }, { it_owner: 'Owns IT setup and equipment' }, {})).toBe('Owns IT setup and equipment')
    expect(recipientTarget({ kind: 'role', role_key: 'manager', person_id: null, email: null }, {}, {})).toBe("The person's manager")
    expect(recipientTarget({ kind: 'person', role_key: null, person_id: 'p1', email: null }, {}, { p1: 'Ana' })).toBe('Ana')
    expect(recipientTarget({ kind: 'email', role_key: null, person_id: null, email: null }, {}, {})).toBe('Address not set')
    expect(recipientSummary({ events: ['hire_confirmed', 'marked_former'], fields: ['name', 'salary'] }, fields)).toBe('On new hire, employment ended · Full name, Salary')
  })
  it('names the events', () => {
    expect(EVENTS.map((e) => e.key)).toEqual(['hire_confirmed', 'onboarding_finished', 'departure_scheduled', 'marked_former'])
    expect(eventLabel('departure_scheduled')).toBe('departure scheduled')
  })
})
