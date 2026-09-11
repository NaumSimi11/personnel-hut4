import { readFileSync } from 'node:fs'
import { fileURLToPath, URL } from 'node:url'
import { defineConfig } from '@playwright/test'

// E2E runs against the real Supabase project with a real test user; the
// credentials live in the repo-root .env.local (gitignored), never here.
function loadRootEnv(): Record<string, string> {
  const raw = readFileSync(fileURLToPath(new URL('../.env.local', import.meta.url)), 'utf8')
  return Object.fromEntries(
    raw
      .split('\n')
      .filter((line) => /^[A-Z0-9_]+=/.test(line))
      .map((line) => {
        const idx = line.indexOf('=')
        return [line.slice(0, idx), line.slice(idx + 1)] as const
      }),
  )
}

const env = loadRootEnv()
process.env.TEST_USER_EMAIL = env.TEST_USER_EMAIL ?? ''
process.env.TEST_USER_PASSWORD = env.TEST_USER_PASSWORD ?? ''
// For test cleanup only (deleting the invited E2E account afterwards).
process.env.SUPABASE_URL = env.SUPABASE_URL ?? ''
process.env.SUPABASE_SECRET_KEY = env.SUPABASE_SECRET_KEY ?? ''

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
