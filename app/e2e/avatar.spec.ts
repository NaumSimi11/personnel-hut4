import { createClient } from '@supabase/supabase-js'
import { expect, test } from '@playwright/test'

/**
 * Profile photos (plan 040): a person adds their own photo from My
 * workspace — squared and shrunk in the browser — it shows in the sidebar
 * and on their record, and can be removed again. The signed-in test user
 * is used as the person; the spec restores whatever photo they had.
 */

const ADMIN_EMAIL = process.env.TEST_USER_EMAIL ?? ''
const ADMIN_PASSWORD = process.env.TEST_USER_PASSWORD ?? ''

// A 1×1 red PNG — enough for createImageBitmap to decode.
const PNG = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==', 'base64')

function serviceClient() {
  const url = process.env.SUPABASE_URL ?? ''
  const key = process.env.SUPABASE_SECRET_KEY ?? ''
  if (!url || !key) throw new Error('SUPABASE_URL / SUPABASE_SECRET_KEY missing in ../.env.local')
  return createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } })
}

let personId = ''
let previousPath: string | null = null

test.beforeAll(async () => {
  test.skip(!ADMIN_EMAIL || !ADMIN_PASSWORD, 'Set TEST_USER_EMAIL / TEST_USER_PASSWORD')
  const db = serviceClient()
  const { data } = await db.from('people').select('id, avatar_url').ilike('work_email', ADMIN_EMAIL).single()
  if (!data) throw new Error('Could not find the test user\'s person row')
  personId = data.id
  previousPath = data.avatar_url
})

test.afterAll(async () => {
  const db = serviceClient()
  const { data } = await db.from('people').select('avatar_url').eq('id', personId).single()
  if (data?.avatar_url && data.avatar_url !== previousPath) await db.storage.from('avatars').remove([data.avatar_url])
  await db.from('people').update({ avatar_url: previousPath }).eq('id', personId)
})

test('add a photo from My workspace → shown in the sidebar and on the record → remove it', async ({ page }) => {
  const db = serviceClient()
  await page.goto('/login')
  await page.locator('#email').fill(ADMIN_EMAIL)
  await page.locator('#password').fill(ADMIN_PASSWORD)
  await page.getByRole('button', { name: 'Sign in' }).click()
  await page.waitForURL(/\/overview/)

  await page.goto('/me')
  await page.getByTestId('avatar-input').setInputFiles({ name: 'me.png', mimeType: 'image/png', buffer: PNG })
  // The hero shows the photo (an <img> inside the avatar) once the upload lands.
  await expect(page.locator('.me-head .avatar.photo img')).toBeVisible()
  await expect(page.locator('.sidebar .avatar.photo img')).toBeVisible()

  const { data: person } = await db.from('people').select('avatar_url').eq('id', personId).single()
  expect(person?.avatar_url).toMatch(new RegExp(`^${personId}/[0-9a-f-]{36}\\.webp$`))
  const { data: files } = await db.storage.from('avatars').list(personId)
  expect((files ?? []).some((f) => `${personId}/${f.name}` === person?.avatar_url)).toBe(true)

  // The directory shows it too.
  await page.goto('/directory')
  await expect(page.locator('.person-cell', { hasText: 'Naum' }).locator('.avatar.photo img').first()).toBeVisible()

  // Remove: the record clears and the file is gone.
  await page.goto('/me')
  page.once('dialog', (d) => d.accept())
  await page.getByRole('button', { name: 'Remove photo' }).click()
  await expect(page.locator('.me-head .avatar.photo')).toHaveCount(0)
  const { data: after } = await db.from('people').select('avatar_url').eq('id', personId).single()
  expect(after?.avatar_url).toBeNull()
  const { data: filesAfter } = await db.storage.from('avatars').list(personId)
  expect((filesAfter ?? []).some((f) => `${personId}/${f.name}` === person?.avatar_url)).toBe(false)
})
