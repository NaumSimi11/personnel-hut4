import type { FastifyInstance } from 'fastify'
import { z } from 'zod'
import { env } from './env.js'
import { RateLimiter } from './careers.js'
import { serviceDb } from './supabaseAdmin.js'
import { deliverPending } from './notificationRoutes.js'

/**
 * The candidate's offer page (0106; spec 6.5, screen 9.12). Anonymous: the
 * 64-character token in the emailed link is the key. The database functions
 * decide what is shown and whether an answer is still possible; these routes
 * only pass them through, rate limited per IP.
 */
const HOUR = 60 * 60 * 1000
const limiter = new RateLimiter({ max: Number(env('OFFER_RATE_IP_PER_HOUR') ?? 60), windowMs: HOUR })
const TOKEN = /^[0-9a-f]{64}$/

const answerInput = z.object({
  answer: z.enum(['accepted', 'declined']),
  reason: z.string().trim().max(2000).optional(),
})

export function registerOfferRoutes(app: FastifyInstance): void {
  app.get<{ Params: { token: string } }>('/api/offer/:token', async (req, reply) => {
    if (!limiter.allow(req.ip)) return reply.status(429).send({ error: 'Too many requests. Try again later.' })
    if (!TOKEN.test(req.params.token)) return reply.status(404).send({ error: 'This offer link is not valid.' })
    const { data, error } = await serviceDb().rpc('offer_for_candidate', { p_token: req.params.token })
    if (error) {
      console.error('[offer] load failed:', error.message)
      return reply.status(500).send({ error: 'The offer could not be loaded. Try again later.' })
    }
    if (!data) return reply.status(404).send({ error: 'This offer link is not valid or no longer open.' })
    return data
  })

  app.post<{ Params: { token: string } }>('/api/offer/:token/answer', async (req, reply) => {
    if (!limiter.allow(req.ip)) return reply.status(429).send({ error: 'Too many requests. Try again later.' })
    if (!TOKEN.test(req.params.token)) return reply.status(404).send({ error: 'This offer link is not valid.' })
    const parsed = answerInput.safeParse(req.body)
    if (!parsed.success) return reply.status(400).send({ error: 'Accept or decline the offer.' })
    const { data, error } = await serviceDb().rpc('answer_offer_by_token', {
      p_token: req.params.token,
      p_answer: parsed.data.answer,
      p_reason: parsed.data.reason ?? null,
    })
    if (error) {
      // The database's own words are written for the candidate (expired, already answered, a reason needed).
      const known = /not valid|already been answered|expired|why you are declining|2,000 characters|Accept or decline/.test(error.message)
      if (!known) console.error('[offer] answer failed:', error.message)
      return reply.status(known ? 400 : 500).send({ error: known ? error.message : 'Your answer could not be saved. Try again later.' })
    }
    // HR hears now rather than at the next sign-in.
    void deliverPending().catch((e: unknown) => console.warn('[offer] notification delivery deferred:', e instanceof Error ? e.message : e))
    return data
  })
}
