import Fastify, { type FastifyInstance } from 'fastify'
import { env } from './env.js'
import { registerRoutes } from './routes.js'
import { registerCareersRoutes } from './careersRoutes.js'
import { registerAppServing } from './serveApp.js'
import { registerNotificationRoutes } from './notificationRoutes.js'
import { registerHandoverRoutes } from './handoverRoutes.js'

/**
 * The whole service as one Fastify instance: auth endpoints, careers
 * intake, and (when a dist folder is given) the built app itself. Both
 * entry points use it — index.ts listens on a port, server.ts exports it
 * for Vercel.
 */
export async function createApp(options: { serveAppDir?: string }): Promise<FastifyInstance> {
  // Behind a reverse proxy the client IP arrives in X-Forwarded-For; the
  // careers rate limit keys on it, so enable this in production.
  const app = Fastify({ logger: { level: 'warn' }, trustProxy: env('TRUST_PROXY') === 'true' })
  registerRoutes(app)
  registerNotificationRoutes(app)
  registerHandoverRoutes(app)
  await registerCareersRoutes(app)
  await registerAppServing(app, options.serveAppDir)
  return app
}
