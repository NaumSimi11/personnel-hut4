import type { IncomingMessage, ServerResponse } from 'node:http'
import type { FastifyInstance } from 'fastify'
import { createApp } from '../src/app.js'

/**
 * Vercel entry point for /api/* (docs/deployment.md). Vercel only turns
 * files inside `api/` into functions, so this catch-all carries the whole
 * service. The built Vue app is not served from here: it lands in
 * `public/` and Vercel's CDN serves it, with the SPA fallback declared as
 * a rewrite in vercel.json.
 *
 * The instance is built once per warm container and reused; Fastify is
 * driven by emitting the request on its own http server, which is the
 * documented way to run it without listening on a port.
 */
let instance: Promise<FastifyInstance> | null = null

export default async function handler(req: IncomingMessage, res: ServerResponse): Promise<void> {
  instance ??= createApp({})
  const app = await instance
  await app.ready()
  app.server.emit('request', req, res)
}
