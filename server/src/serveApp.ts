import { existsSync } from 'node:fs'
import { resolve } from 'node:path'
import type { FastifyInstance } from 'fastify'
import fastifyStatic from '@fastify/static'

/**
 * Serve the built Vue app from this process so production is one origin:
 * the app and its /api endpoints on one host, no CORS, no proxy rewrites.
 * Enabled by SERVE_APP_DIR (the app's dist folder). Unknown paths outside
 * /api get index.html — the router owns those — while /api keeps its 404s.
 */
export async function registerAppServing(app: FastifyInstance, dir: string | undefined): Promise<void> {
  if (!dir) return
  const root = resolve(dir)
  if (!existsSync(resolve(root, 'index.html'))) {
    throw new Error(`SERVE_APP_DIR has no index.html: ${root} (build the app first)`)
  }
  await app.register(fastifyStatic, { root, wildcard: false, index: ['index.html'] })
  app.setNotFoundHandler((request, reply) => {
    if (request.url.startsWith('/api/') || request.method !== 'GET') {
      return reply.code(404).send({ error: 'Not found' })
    }
    return reply.sendFile('index.html')
  })
}
