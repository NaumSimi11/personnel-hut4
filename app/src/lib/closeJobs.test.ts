import { describe, expect, it } from 'vitest'
import {
  closeQuestion,
  closeSelection,
  closeSummary,
  friendlyCloseError,
  whyNotSelectable,
  type CloseTarget,
} from './closeJobs'

const job = (over: Partial<CloseTarget> = {}): CloseTarget => ({
  id: 'j1',
  title: 'Role',
  company: 'Hut4',
  status: 'open',
  inPlay: 0,
  mayEdit: true,
  mayWithdraw: true,
  ...over,
})

describe('closeSelection', () => {
  it('counts what will close, what is closed already, and who is waiting', () => {
    const s = closeSelection([job({ inPlay: 3 }), job({ id: 'j2', status: 'closed', inPlay: 1 }), job({ id: 'j3', status: 'on_hold' })])
    expect(s).toEqual({ jobs: 3, toClose: 2, alreadyClosed: 1, inPlay: 4, mayWithdraw: true, withdrawBlockedBy: null })
  })

  it('is empty for an empty selection, and offers no withdrawal', () => {
    expect(closeSelection([])).toEqual({ jobs: 0, toClose: 0, alreadyClosed: 0, inPlay: 0, mayWithdraw: false, withdrawBlockedBy: null })
  })

  it('one company the viewer cannot review in takes the withdrawal off the whole call, and is named', () => {
    const s = closeSelection([job({ inPlay: 3 }), job({ id: 'j2', company: 'Praedium', mayWithdraw: false })])
    expect(s.mayWithdraw).toBe(false)
    expect(s.withdrawBlockedBy).toBe('Praedium')
    // The close itself is still on the table — that is the point of refusing
    // only the withdrawal.
    expect(s.toClose).toBe(2)
  })
})

describe('whyNotSelectable', () => {
  it('names the missing permission', () => {
    expect(whyNotSelectable(job({ mayEdit: false }))).toBe('You cannot edit jobs in this company.')
  })

  it('lets an already-closed row be picked — the call counts it and leaves it alone', () => {
    expect(whyNotSelectable(job({ status: 'closed' }))).toBeNull()
  })
})

describe('closeQuestion', () => {
  it('says nothing will change when everything picked is closed and settled', () => {
    expect(closeQuestion(closeSelection([job({ status: 'closed' })]), false)).toBe(
      'That opening is already closed. Nothing will change.',
    )
    expect(closeQuestion(closeSelection([job({ status: 'closed' }), job({ id: 'j2', status: 'closed' })]), true)).toBe(
      'All 2 are already closed. Nothing will change.',
    )
  })

  it('still offers the withdrawal when a closed opening has people waiting on it', () => {
    const s = closeSelection([job({ status: 'closed', inPlay: 4 })])
    expect(closeQuestion(s, false)).toBe('That opening is already closed, but 4 candidates on it are still in play.')
    expect(closeQuestion(s, true)).toBe(
      'That opening is already closed. 4 candidates still in play will be withdrawn with the reason below.',
    )
  })

  it('warns that candidates keep counting when they are not withdrawn', () => {
    expect(closeQuestion(closeSelection([job({ inPlay: 2 })]), false)).toBe(
      '1 opening will close. 2 candidates stay in play and keep counting until somebody answers them.',
    )
  })

  it('says how many will be withdrawn before the button is pressed', () => {
    expect(closeQuestion(closeSelection([job({ inPlay: 1 })]), true)).toBe(
      '1 opening will close and 1 candidate still in play will be withdrawn with the reason below.',
    )
  })

  it('mentions the rows that are closed already', () => {
    const s = closeSelection([job({ inPlay: 2 }), job({ id: 'j2', status: 'closed' })])
    expect(closeQuestion(s, true)).toBe(
      '1 opening will close and 2 candidates still in play will be withdrawn with the reason below. 1 other in the selection is already closed and stays as it is.',
    )
  })

  it('does not promise a withdrawal when nobody is in play', () => {
    expect(closeQuestion(closeSelection([job(), job({ id: 'j2' })]), true)).toBe('2 openings will close.')
  })
})

describe('closeSummary', () => {
  it('reports the three counts', () => {
    expect(closeSummary({ closed: 2, already_closed: 1, withdrawn: 7 })).toBe(
      '2 openings closed · 1 was closed already · 7 candidates withdrawn.',
    )
  })

  it('leaves out what did not happen', () => {
    expect(closeSummary({ closed: 1, already_closed: 0, withdrawn: 0 })).toBe('1 opening closed.')
  })

  it('says so when there was nothing left to close', () => {
    expect(closeSummary({ closed: 0, already_closed: 3, withdrawn: 0 })).toBe('Nothing left to close · 3 were closed already.')
  })
})

describe('friendlyCloseError', () => {
  it('turns the RLS refusal into the missing permission', () => {
    expect(friendlyCloseError('new row violates row-level security policy for table "jobs"')).toBe(
      'You cannot edit jobs in this company.',
    )
  })

  it("passes the database's own sentences through", () => {
    const raised = 'You need "Edit job descriptions" in Hut4 to close Backend Developer.'
    expect(friendlyCloseError(raised)).toBe(raised)
  })
})
