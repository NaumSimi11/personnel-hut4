/**
 * Produce a Vercel Build Output API (v3) deployment in .vercel/output/:
 *
 *   static/               the Vue build, served by Vercel's CDN
 *   functions/api.func/   ONE self-contained function handling /api/*
 *   config.json           routing: filesystem first, /api/* to the function,
 *                         everything else falls back to the SPA's index.html
 *
 * Declaring the output instead of relying on Vercel's zero-config detection
 * is what the Hut4 leave system does, and it is what makes this deployable
 * at all: the service imports ../../shared, which lives outside the project's
 * Root Directory, and esbuild inlines it here at build time so the function
 * needs nothing outside its own bundle.
 *
 * Run through `npm run build:vercel`; the Vue build must already be in
 * ../app/dist (vercel.json chains them).
 */
import { build } from 'esbuild'
import { cpSync, existsSync, mkdirSync, rmSync, writeFileSync } from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const out = path.join(root, '.vercel', 'output')
const clientDist = path.resolve(root, '..', 'app', 'dist')

if (!existsSync(path.join(clientDist, 'index.html'))) {
  console.error(`No built app at ${clientDist} — run the app's build first (npm run build:vercel does).`)
  process.exit(1)
}

rmSync(out, { recursive: true, force: true })
const funcDir = path.join(out, 'functions', 'api.func')
mkdirSync(funcDir, { recursive: true })

await build({
  entryPoints: [path.join(root, 'api', 'index.ts')],
  bundle: true,
  platform: 'node',
  // ESM, because the service reads import.meta.url (env.ts) — that cannot be
  // expressed in CommonJS output.
  format: 'esm',
  target: 'node22',
  outfile: path.join(funcDir, 'index.js'),
  logLevel: 'error',
  // Fastify and its plugins are CommonJS and require() Node built-ins at load
  // time. ESM output has no require, so give the bundle a real one — without
  // it the function dies on import with "Dynamic require of node:events".
  banner: {
    js: "import { createRequire as __createRequire } from 'node:module';\nconst require = __createRequire(import.meta.url);",
  },
})

writeFileSync(
  path.join(funcDir, '.vc-config.json'),
  JSON.stringify(
    {
      runtime: 'nodejs22.x',
      handler: 'index.js',
      // A request wedged on Supabase should die rather than hang to the
      // platform ceiling: the client can retry a failure, not a silence.
      maxDuration: 30,
      launcherType: 'Nodejs',
      // Raw IncomingMessage/ServerResponse — what Fastify expects to be fed.
      shouldAddHelpers: false,
    },
    null,
    2,
  ) + '\n',
)
writeFileSync(path.join(funcDir, 'package.json'), JSON.stringify({ type: 'module' }, null, 2) + '\n')

cpSync(clientDist, path.join(out, 'static'), { recursive: true })

writeFileSync(
  path.join(out, 'config.json'),
  JSON.stringify(
    {
      version: 3,
      routes: [
        // Before the filesystem lookup: every /api/* path is rewritten onto
        // /api so the lookup resolves it to api.func. Rewriting after the
        // lookup leaves sub-paths unresolved — only bare /api reaches the
        // function.
        { src: '^/api(?:/.*)?$', dest: '/api' },
        { handle: 'filesystem' },
        // Anything left is a client route: the SPA owns it.
        { src: '^/(?!api/).*$', dest: '/index.html' },
      ],
    },
    null,
    2,
  ) + '\n',
)

console.warn('Vercel build output written to .vercel/output')
