import { mkdtempSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { describe, expect, it } from 'vitest'
import { createApp } from './app.js'

describe('createApp', () => {
  it('has the API routes and the SPA fallback when a dist folder is given', async () => {
    const dir = mkdtempSync(join(tmpdir(), 'personnel-dist-'))
    writeFileSync(join(dir, 'index.html'), '<title>Personnel</title>')
    const app = await createApp({ serveAppDir: dir })
    expect((await app.inject({ url: '/api/health' })).json()).toEqual({ ok: true })
    expect((await app.inject('/people/x')).body).toContain('<title>Personnel</title>')
  })

  it('answers only the API without one', async () => {
    const app = await createApp({})
    expect((await app.inject('/people/x')).statusCode).toBe(404)
  })
})
