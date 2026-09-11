import Fastify from 'fastify'
import { env } from './env.js'
import { registerRoutes } from './routes.js'

const app = Fastify({ logger: { level: 'warn' } })
registerRoutes(app)

const port = Number(env('AUTH_SERVICE_PORT') ?? 8787)
app
  .listen({ port, host: '127.0.0.1' })
  .then(() => console.warn(`[auth-service] listening on http://127.0.0.1:${port}`))
  .catch((error) => {
    console.error('[auth-service] failed to start:', error)
    process.exit(1)
  })
