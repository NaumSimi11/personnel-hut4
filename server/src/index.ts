import Fastify from 'fastify'
import { env } from './env.js'
import { registerRoutes } from './routes.js'
import { registerCareersRoutes } from './careersRoutes.js'
import { registerAppServing } from './serveApp.js'

// Behind a reverse proxy the client IP arrives in X-Forwarded-For; the careers
// rate limit keys on it, so enable this in production (TRUST_PROXY=true).
const app = Fastify({ logger: { level: 'warn' }, trustProxy: env('TRUST_PROXY') === 'true' })
registerRoutes(app)

const port = Number(env('PORT') ?? env('AUTH_SERVICE_PORT') ?? 8787)
// Loopback in development (Vite proxies /api); HOST=0.0.0.0 in a container.
const host = env('HOST') ?? '127.0.0.1'
registerCareersRoutes(app)
  // In production the same process serves the built app (SERVE_APP_DIR).
  .then(() => registerAppServing(app, env('SERVE_APP_DIR')))
  .then(() => app.listen({ port, host }))
  .then(() => console.warn(`[auth-service] listening on http://${host}:${port}`))
  .catch((error) => {
    console.error('[auth-service] failed to start:', error)
    process.exit(1)
  })
