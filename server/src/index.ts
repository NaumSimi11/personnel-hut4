import Fastify from 'fastify'
import { env } from './env.js'
import { registerRoutes } from './routes.js'
import { registerCareersRoutes } from './careersRoutes.js'

// Behind a reverse proxy the client IP arrives in X-Forwarded-For; the careers
// rate limit keys on it, so enable this in production (TRUST_PROXY=true).
const app = Fastify({ logger: { level: 'warn' }, trustProxy: env('TRUST_PROXY') === 'true' })
registerRoutes(app)

const port = Number(env('AUTH_SERVICE_PORT') ?? 8787)
registerCareersRoutes(app)
  .then(() => app.listen({ port, host: '127.0.0.1' }))
  .then(() => console.warn(`[auth-service] listening on http://127.0.0.1:${port}`))
  .catch((error) => {
    console.error('[auth-service] failed to start:', error)
    process.exit(1)
  })
