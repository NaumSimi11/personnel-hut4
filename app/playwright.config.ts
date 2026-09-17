import { readFileSync } from 'node:fs'
import { fileURLToPath, URL } from 'node:url'
import { defineConfig } from '@playwright/test'

// E2E runs against the real Supabase project with a real test user; the
// credentials live in the repo-root .env.local (gitignored), never here.
function loadRootEnv(): Record<string, string> {
  const raw = readFileSync(fileURLToPath(new URL('../.env.local', import.meta.url)), 'utf8')
  // Split on either line ending: a CRLF file would otherwise leave a trailing
  // "\r" on every value, which sign-in tolerates but exact DB lookups don't.
  return Object.fromEntries(
    raw
      .split(/\r?\n/)
      .filter((line) => /^[A-Z0-9_]+=/.test(line))
      .map((line) => {
        const idx = line.indexOf('=')
        return [line.slice(0, idx), line.slice(idx + 1).trim()] as const
      }),
  )
}

const env = loadRootEnv()
process.env.TEST_USER_EMAIL = env.TEST_USER_EMAIL ?? ''
process.env.TEST_USER_PASSWORD = env.TEST_USER_PASSWORD ?? ''
// For test cleanup only (deleting the invited E2E account afterwards).
process.env.SUPABASE_URL = env.SUPABASE_URL ?? ''
process.env.SUPABASE_SECRET_KEY = env.SUPABASE_SECRET_KEY ?? ''

// The suite builds a service-key client — which bypasses row-level security —
// and its teardown hard-deletes people. The only Supabase project configured
// here is the one the deployed app serves, so a run mutates live records.
//
// That is deliberate, but it must never happen by accident: a stray `npm run
// test:e2e` has already removed people out from under someone using the app,
// leaving notifications pointing at records that no longer exist. So the run
// takes an explicit acknowledgement rather than a silent assumption.
if ((env.E2E_ALLOW_PRODUCTION ?? '').trim().toLowerCase() !== 'true') {
  throw new Error(
    'Refusing to run E2E: these tests write to — and delete from — the live ' +
      `Supabase project (${env.SUPABASE_URL || 'SUPABASE_URL unset'}), which is ` +
      'the same one the deployed app serves.\n\n' +
      'If that is what you intend, set E2E_ALLOW_PRODUCTION=true in .env.local. ' +
      'To keep production untouched, point SUPABASE_URL and ' +
      'VITE_SUPABASE_URL at a separate project first.',
  )
}

export default defineConfig({
  testDir: './e2e',
  timeout: 60000,
  workers: 1, // flows share one live database; keep them sequential
  use: { baseURL: 'http://localhost:5199' },
  webServer: [
    {
      command: 'npm run dev -- --port 5199 --strictPort',
      url: 'http://localhost:5199/login',
      reuseExistingServer: true,
      timeout: 30000,
    },
    {
      // The privileged auth service (invite / reset / change password).
      command: 'npm run dev --prefix ../server',
      url: 'http://127.0.0.1:8787/api/health',
      reuseExistingServer: true,
      timeout: 30000,
    },
  ],
})
