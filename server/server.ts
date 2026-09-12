import { fileURLToPath } from 'node:url'
import Fastify from 'fastify'
import { createApp } from './src/app.js'

/**
 * Vercel entry point (docs/deployment.md): the project's Root Directory is
 * `server/`, Vercel detects Fastify here and runs the exported instance as
 * a function. The built Vue app lands in `public/` (served by Vercel's CDN
 * directly); the function only answers /api and the SPA fallback.
 */
void Fastify // the framework import is what Vercel's entrypoint detection looks for
export default await createApp({ serveAppDir: fileURLToPath(new URL('./public', import.meta.url)) })
