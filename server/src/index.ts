import { createApp } from './app.js'
import { env } from './env.js'

const port = Number(env('PORT') ?? env('AUTH_SERVICE_PORT') ?? 8787)
// Loopback in development (Vite proxies /api); HOST=0.0.0.0 in a container.
const host = env('HOST') ?? '127.0.0.1'
// In production the same process serves the built app (SERVE_APP_DIR).
createApp({ serveAppDir: env('SERVE_APP_DIR') })
  .then((app) => app.listen({ port, host }))
  .then(() => console.warn(`[auth-service] listening on http://${host}:${port}`))
  .catch((error) => {
    console.error('[auth-service] failed to start:', error)
    process.exit(1)
  })
