import { describe, expect, it } from 'vitest'
import {
  dueLabel,
  dueTone,
  friendlyTaskError,
  openCount,
  orderTasks,
  ownerLine,
  readMyTasks,
  taskInput,
  withLine,
  type MyTask,
} from './tasks'

const TODAY = '2026-09-23'

const task = (over: Partial<MyTask> = {}): MyTask => ({
  id: 't1',
  person_id: 'p1',
  title: 'Book the room',
  detail: null,
  due_date: null,
  status: 'open',
  created_by: 'p1',
  created_at: '2026-09-20T09:00:00Z',
  done_at: null,
  person_name: 'Tomo Task',
  created_by_name: 'Tomo Task',
  done_by_name: null,
  with_people: [],
  is_mine: true,
  ...over,
})

describe('taskInput', () => {
  it('insists on a title', () => {
    expect(taskInput.safeParse({ title: '   ' }).success).toBe(false)
    expect(taskInput.safeParse({ title: 'x'.repeat(201) }).success).toBe(false)
    expect(taskInput.safeParse({ title: 'Book the room' }).success).toBe(true)
  })

  it('refuses a note longer than the column and a date that is not one', () => {
    expect(taskInput.safeParse({ title: 'ok', detail: 'x'.repeat(2001) }).success).toBe(false)
    expect(taskInput.safeParse({ title: 'ok', due_date: '5 October' }).success).toBe(false)
    expect(taskInput.safeParse({ title: 'ok', due_date: '2026-10-05' }).success).toBe(true)
  })
})

describe('readMyTasks', () => {
  it('survives a shape it was not promised', () => {
    expect(readMyTasks(null)).toEqual({ mine: [], set_by_me: [] })
    expect(readMyTasks({ mine: 'nope' })).toEqual({ mine: [], set_by_me: [] })
    expect(readMyTasks({ mine: [task()], set_by_me: [] }).mine).toHaveLength(1)
  })
})

describe('dueTone / dueLabel', () => {
  it('reads a date against today', () => {
    expect(dueTone(task({ due_date: '2026-09-22' }), TODAY)).toBe('overdue')
    expect(dueTone(task({ due_date: TODAY }), TODAY)).toBe('today')
    expect(dueTone(task({ due_date: '2026-09-30' }), TODAY)).toBe('soon')
    expect(dueTone(task({ due_date: '2026-10-01' }), TODAY)).toBe('later')
    expect(dueTone(task({ due_date: null }), TODAY)).toBe('none')
  })

  it('never calls a finished task overdue', () => {
    expect(dueTone(task({ due_date: '2026-01-01', status: 'done' }), TODAY)).toBe('none')
  })

  it('says it in words', () => {
    expect(dueLabel(task({ due_date: '2026-09-22' }), TODAY)).toBe('overdue · 22 Sep')
    expect(dueLabel(task({ due_date: TODAY }), TODAY)).toBe('due today')
    expect(dueLabel(task({ due_date: '2026-10-05' }), TODAY)).toBe('due 5 Oct')
    expect(dueLabel(task({ due_date: null }), TODAY)).toBeNull()
  })
})

describe('orderTasks', () => {
  it('puts open first, then the nearest date, then undated, then the done', () => {
    const rows = [
      task({ id: 'done', status: 'done', due_date: '2026-09-01' }),
      task({ id: 'undated' }),
      task({ id: 'later', due_date: '2026-10-01' }),
      task({ id: 'soon', due_date: '2026-09-24' }),
    ]
    expect(orderTasks(rows).map((t) => t.id)).toEqual(['soon', 'later', 'undated', 'done'])
  })

  it('breaks a tie by when it was written, oldest first', () => {
    const rows = [
      task({ id: 'new', created_at: '2026-09-21T09:00:00Z' }),
      task({ id: 'old', created_at: '2026-09-19T09:00:00Z' }),
    ]
    expect(orderTasks(rows).map((t) => t.id)).toEqual(['old', 'new'])
  })
})

describe('openCount', () => {
  it('counts what is left to do', () => {
    expect(openCount([task(), task({ status: 'done' }), task()])).toBe(2)
  })
})

describe('ownerLine / withLine', () => {
  it('names the owner only when the task is somebody else’s', () => {
    expect(ownerLine(task())).toBeNull()
    expect(ownerLine(task({ is_mine: false, person_name: 'Tina Task' }))).toBe("Tina Task's task")
  })

  it('lists the colleagues on it, in English', () => {
    expect(withLine(task())).toBeNull()
    expect(withLine(task({ with_people: [{ id: 'a', full_name: 'Ana' }] }))).toBe('with Ana')
    expect(
      withLine(task({ with_people: [{ id: 'a', full_name: 'Ana' }, { id: 'b', full_name: 'Ben' }] })),
    ).toBe('with Ana and Ben')
    expect(
      withLine(
        task({
          with_people: [
            { id: 'a', full_name: 'Ana' },
            { id: 'b', full_name: 'Ben' },
            { id: 'c', full_name: 'Cy' },
          ],
        }),
      ),
    ).toBe('with Ana, Ben and Cy')
  })
})

describe('friendlyTaskError', () => {
  it('passes the database’s own sentence through', () => {
    const raised = "You cannot put a task on Tina Task's list."
    expect(friendlyTaskError(raised)).toBe(raised)
  })

  it('translates the ones written for a machine', () => {
    expect(friendlyTaskError('new row violates row-level security policy')).toBe('That task is not yours to change.')
  })
})
