import type { FastifyInstance } from 'fastify'
import { createClient } from '@supabase/supabase-js'
import { env } from './env.js'
import { identityFromToken, serviceDb } from './supabaseAdmin.js'
import { formTitle, renderEquipmentForm, type EquipmentFormData } from './equipmentForms.js'
import { renderWelcomeNote, type WelcomeNoteData } from './welcomeNote.js'

/**
 * POST /api/documents/generate — makes the documents the database queued
 * (plan 049): the equipment handover form on issue, the return form when
 * a departure is scheduled. The queue is read as the caller, so only rows
 * they may see (tasks.view / it.view in the company) are worked; the
 * privileged part — reading what the person holds, writing the file,
 * recording the document under the requester's name — runs as the
 * service. Called by the app's delivery kick, so a scheduled departure
 * produces its form without a click.
 */

const BATCH = 20
const MAX_ATTEMPTS = 5
const BUCKET = 'employee-documents'
const KINDS = ['equipment_handover', 'equipment_return', 'welcome_note'] as const
let running = false

type QueueRow = { id: string; kind: (typeof KINDS)[number]; person_id: string; company_id: string; plan_id: string | null; attempts: number }

export async function generatePending(token: string): Promise<{ made: number; failed: number }> {
  const url = env('SUPABASE_URL') ?? ''
  const anon = env('SUPABASE_PUBLISHABLE_KEY') ?? env('VITE_SUPABASE_PUBLISHABLE_KEY') ?? ''
  const asCaller = createClient(url, anon, { global: { headers: { Authorization: `Bearer ${token}` } }, auth: { persistSession: false, autoRefreshToken: false } })
  // Only the kinds this route can make, so a kind another slice owns never fills the batch;
  // a failed row is tried again until it has had its five attempts.
  const { data: rows, error } = await asCaller
    .from('generated_documents')
    .select('id, kind, person_id, company_id, plan_id, attempts')
    .in('kind', [...KINDS])
    .in('status', ['pending', 'failed'])
    .lt('attempts', MAX_ATTEMPTS)
    .order('created_at', { ascending: true })
    .limit(BATCH)
  if (error) throw new Error(error.message)
  const db = serviceDb()
  const result = { made: 0, failed: 0 }
  for (const q of (rows ?? []) as QueueRow[]) {
    try {
      let pdf: Buffer
      let title: string
      if (q.kind === 'welcome_note') {
        const { data: note, error: dataErr } = await db.rpc('welcome_note_data', { p_queue_id: q.id })
        if (dataErr || !note) throw new Error(dataErr?.message ?? 'no note data')
        const data = note as WelcomeNoteData
        pdf = await renderWelcomeNote(data)
        title = data.subject
      } else {
        const { data: form, error: dataErr } = await db.rpc('equipment_form_data', { p_queue_id: q.id })
        if (dataErr || !form) throw new Error(dataErr?.message ?? 'no form data')
        pdf = await renderEquipmentForm(form as EquipmentFormData)
        title = formTitle(q.kind)
      }
      const documentId = crypto.randomUUID()
      const path = `${q.company_id}/${q.person_id}/${documentId}.pdf`
      const { error: upErr } = await db.storage.from(BUCKET).upload(path, pdf, { contentType: 'application/pdf' })
      if (upErr) throw new Error(upErr.message)
      const { error: recErr } = await db.rpc('record_generated_document', { p_queue_id: q.id, p_storage_path: path, p_size_bytes: pdf.length, p_title: title })
      if (recErr) {
        await db.storage.from(BUCKET).remove([path])
        throw new Error(recErr.message)
      }
      result.made += 1
    } catch (e) {
      const message = e instanceof Error ? e.message : String(e)
      console.warn(`[documents] ${q.kind} ${q.id} not generated (attempt ${q.attempts + 1}):`, message)
      await db.from('generated_documents').update({ status: 'failed', error: message, attempts: q.attempts + 1 }).eq('id', q.id)
      result.failed += 1
    }
  }
  return result
}

export function registerDocumentRoutes(app: FastifyInstance): void {
  app.post('/api/documents/generate', async (req, reply) => {
    const token = req.headers.authorization?.replace(/^Bearer\s+/i, '')
    const identity = token ? await identityFromToken(token) : null
    if (!identity || !token || identity.mustChangePassword) return reply.status(401).send({ error: 'Sign in to continue.' })
    if (running) return { made: 0, failed: 0, busy: true }
    running = true
    try {
      return await generatePending(token)
    } catch (e) {
      console.error('[documents] generation failed:', e instanceof Error ? e.message : e)
      return reply.status(500).send({ error: 'Generation failed; the documents are still queued.' })
    } finally {
      running = false
    }
  })
}
