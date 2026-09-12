import { mkdtempSync, mkdirSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import Fastify from 'fastify'
import { describe, expect, it } from 'vitest'
import { registerAppServing } from './serveApp.js'

function appDir(): string {
  const dir = mkdtempSync(join(tmpdir(), 'personnel-app-'))
  writeFileSync(join(dir, 'index.html'), '<!doctype html><title>Personnel</title>')
  mkdirSync(join(dir, 'assets'))
  writeFileSync(join(dir, 'assets', 'app.js'), 'console.log(1)')
  return dir
}

describe('registerAppServing', () => {
  it('serves built files, falls back to index.html for app routes, never for /api', async () => {
    const app = Fastify()
    app.get('/api/health', async () => ({ ok: true }))
    await registerAppServing(app, appDir())
    expect((await app.inject('/assets/app.js')).body).toBe('console.log(1)')
    const spa = await app.inject('/leave?tab=requests')
    expect(spa.statusCode).toBe(200)
    expect(spa.body).toContain('<title>Personnel</title>')
    expect((await app.inject('/api/health')).json()).toEqual({ ok: true })
    expect((await app.inject('/api/nothing')).statusCode).toBe(404)
  })

  it('does nothing when no directory is configured', async () => {
    const app = Fastify()
    await registerAppServing(app, undefined)
    expect((await app.inject('/')).statusCode).toBe(404)
  })
})
