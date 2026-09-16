import type { IncomingMessage, ServerResponse } from 'node:http'

/**
 * Deployment probe: answers without touching Supabase or Fastify, so a
 * response here means Vercel built this directory into functions at all.
 */
export default function handler(_req: IncomingMessage, res: ServerResponse): void {
  res.setHeader('content-type', 'application/json')
  res.end(JSON.stringify({ ok: true }))
}
