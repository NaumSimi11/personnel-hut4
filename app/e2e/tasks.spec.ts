import { createClient } from '@supabase/supabase-js'
import { expect, test } from '@playwright/test'
import { confirmDialog } from './support/dialogs'

/**
 * Tasks that stand on their own (plan 057). The admin writes one down for
 * themselves from My workspace, gives it a due date and a note, connects a
 * colleague, ticks it off, shows the finished ones again, and deletes it.
 *
 * Nothing is seeded: the point of the feature is that anybody can write a
 * task with no setup at all. The spec cleans its own rows by title before
 * and after, through the service key, since a failed run must not leave a
 * task on a real person's list.
 */

const ADMIN_EMAIL = process.env.TEST_USER_EMAIL ?? ''
const ADMIN_PASSWORD = process.env.TEST_USER_PASSWORD ?? ''
const TITLE = 'E2E Task — book the room'
const RETITLED = 'E2E Task — book the big room'
const NOTE = 'E2E: for the Monday review'

function serviceClient() {
  const url = process.env.SUPABASE_URL ?? ''
  const key = process.env.SUPABASE_SECRET_KEY ?? ''
  if (!url || !key) throw new Error('SUPABASE_URL / SUPABASE_SECRET_KEY missing in ../.env.local')
  return createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } })
}

async function cleanup(): Promise<void> {
  const db = serviceClient()
  const { data } = await db.from('tasks').select('id').like('title', 'E2E Task%')
  const ids = (data ?? []).map((t) => t.id)
  if (ids.length) {
    await db.from('task_people').delete().in('task_id', ids)
    await db.from('tasks').delete().in('id', ids)
  }
  await db.from('notifications').delete().like('title', '%E2E Task%')
}

test.beforeAll(async () => {
  test.skip(!ADMIN_EMAIL || !ADMIN_PASSWORD, 'Set TEST_USER_EMAIL / TEST_USER_PASSWORD')
  await cleanup()
})

test.afterAll(async () => {
  await cleanup()
})

test('a person writes a task down, connects a colleague, ticks it and deletes it', async ({ page }) => {
  test.skip(!ADMIN_EMAIL || !ADMIN_PASSWORD, 'Set TEST_USER_EMAIL / TEST_USER_PASSWORD')

  await page.goto('/login')
  await page.locator('#email').fill(ADMIN_EMAIL)
  await page.locator('#password').fill(ADMIN_PASSWORD)
  await page.getByRole('button', { name: 'Sign in' }).click()
  await page.waitForURL(/\/overview/)

  await page.goto('/me')
  const card = page.getByTestId('my-tasks-card')
  await expect(card).toBeVisible()

  // Write one down.
  await page.getByTestId('task-add').click()
  await expect(page.getByTestId('task-dialog')).toBeVisible()
  await page.getByTestId('task-title').fill(TITLE)
  await page.getByTestId('task-detail').fill(NOTE)
  await page.getByTestId('task-due').fill('2026-10-05')
  await page.getByTestId('task-save').click()

  await expect(card).toContainText(TITLE)
  await expect(card).toContainText(NOTE)
  await expect(card).toContainText('due 5 Oct')

  const db = serviceClient()
  const { data: written } = await db.from('tasks').select('id, status, due_date, detail').eq('title', TITLE).single()
  expect(written?.status).toBe('open')
  expect(written?.due_date).toBe('2026-10-05')
  const taskId = written?.id as string

  // A title with nothing in it is refused in the form, before any round trip.
  await page.getByTestId('task-add').click()
  await page.getByTestId('task-title').fill('   ')
  await page.getByTestId('task-save').click()
  await expect(page.getByTestId('task-dialog-error')).toContainText('Give the task a title.')
  await page.getByRole('button', { name: 'Cancel' }).click()

  // Change it, and connect the first colleague offered.
  await page.getByTestId(`task-edit-${taskId}`).click()
  await page.getByTestId('task-title').fill(RETITLED)
  const firstColleague = page.locator('[data-testid^="task-with-"]').first()
  const connected = (await firstColleague.count()) > 0
  if (connected) await firstColleague.check()
  await page.getByTestId('task-save').click()
  await expect(card).toContainText(RETITLED)
  if (connected) {
    await expect(card).toContainText('with ')
    const { data: people } = await db.from('task_people').select('person_id').eq('task_id', taskId)
    expect(people?.length).toBe(1)
  }

  // Tick it off: it leaves the open list, and comes back when done are shown.
  await page.getByTestId(`task-tick-${taskId}`).check()
  await expect(page.getByTestId(`task-${taskId}`)).toHaveCount(0)
  await page.getByTestId('tasks-toggle-done').click()
  await expect(page.getByTestId(`task-${taskId}`)).toBeVisible()

  const { data: ticked } = await db.from('tasks').select('status, done_at, done_by').eq('id', taskId).single()
  expect(ticked?.status).toBe('done')
  expect(ticked?.done_at).not.toBeNull()
  expect(ticked?.done_by).not.toBeNull()

  // And delete it.
  await page.getByTestId(`task-delete-${taskId}`).click()
  await confirmDialog(page)
  await expect(page.getByTestId(`task-${taskId}`)).toHaveCount(0)
  const { data: gone } = await db.from('tasks').select('id').eq('id', taskId)
  expect(gone).toHaveLength(0)
})
