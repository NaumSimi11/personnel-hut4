import type { FastifyInstance } from 'fastify'
import { createClient } from '@supabase/supabase-js'
import { env } from './env.js'
import { identityFromToken, serviceDb } from './supabaseAdmin.js'
import { renderContract } from './contractPdf.js'
import { canIssue, labelFor, renderTemplate } from '../../shared/contractTemplate.js'

/**
 * POST /api/contracts/issue — fills a published template with one person's
 * facts, renders it, and files it as that person's document.
 *
 * The template is read AS THE CALLER, and so are the values: whether someone
 * may see a national ID or a salary is decided by the database's own rules, not
 * by this route. Only the writing runs as the service, because filing a
 * document under a person needs privileges the caller does not have.
 *
 * Rendering refuses when a required field has no value. That refusal is the
 * feature: an employment contract with a blank where the salary belongs is
 * worse than no contract, and it is the kind of thing nobody notices until it
 * matters.
 *
 * The signing is on paper. These are employment contracts, and the in-app
 * signature (0053) is a simple electronic one — enough for handing a laptop
 * back, not for this. The app prints; the parties sign; the scan returns as
 * version 2 through the ordinary document upload.
 */

const BUCKET = 'employee-documents'

type IssueBody = {
  templateId?: string
  personId?: string
  employmentId?: string | null
}

export function registerContractRoutes(app: FastifyInstance): void {
  app.post('/api/contracts/issue', async (req, reply) => {
    const token = (req.headers.authorization ?? '').replace(/^Bearer /, '')
    if (!token) return reply.code(401).send({ error: 'Sign in to continue.' })
    const who = await identityFromToken(token)
    if (!who) return reply.code(401).send({ error: 'Sign in to continue.' })

    const { templateId, personId, employmentId } = (req.body ?? {}) as IssueBody
    if (!templateId || !personId) {
      return reply.code(400).send({ error: 'A template and a person are needed.' })
    }

    const url = env('SUPABASE_URL') ?? ''
    const anon = env('SUPABASE_PUBLISHABLE_KEY') ?? env('VITE_SUPABASE_PUBLISHABLE_KEY') ?? ''
    const asCaller = createClient(url, anon, {
      global: { headers: { Authorization: `Bearer ${token}` } },
      auth: { persistSession: false, autoRefreshToken: false },
    })

    const [tplRes, valRes] = await Promise.all([
      asCaller.from('contract_templates').select('id, title, body, version, status, category_key, company_id').eq('id', templateId).maybeSingle(),
      asCaller.rpc('contract_values', { p_person_id: personId, p_employment_id: employmentId ?? undefined }),
    ])
    if (tplRes.error || !tplRes.data) {
      return reply.code(404).send({ error: 'That template is not available to you.' })
    }
    if (valRes.error) {
      return reply.code(403).send({ error: valRes.error.message })
    }
    const template = tplRes.data
    if (template.status !== 'published') {
      return reply.code(400).send({ error: 'Publish the template before issuing it.' })
    }

    const values = (valRes.data ?? {}) as Record<string, string>
    const rendered = renderTemplate(template.body, values)
    if (!canIssue(rendered)) {
      // Named, not counted: "three fields are missing" sends someone hunting.
      return reply.code(422).send({
        error: 'This contract cannot be issued yet.',
        missing: rendered.missing.map(labelFor),
        unknown: rendered.unknown,
      })
    }

    const issuedOn = values.today ?? new Date().toISOString().slice(0, 10)
    const pdf = await renderContract({
      title: template.title,
      companyName: values.company_legal_name ?? values.company ?? '',
      personName: values.full_name ?? '',
      body: rendered.text,
      issuedOn,
      version: template.version,
    })

    const db = serviceDb()
    // identityFromToken carries the auth user, not the employee record.
    const { data: me } = await db.from('people').select('id').eq('user_id', who.id).maybeSingle()
    const path = `${template.company_id ?? 'holding'}/${personId}/${template.category_key}-${Date.now()}.pdf`
    const { error: upErr } = await db.storage.from(BUCKET).upload(path, pdf, { contentType: 'application/pdf' })
    if (upErr) {
      req.log.error({ err: upErr.message }, 'contract upload failed')
      return reply.code(500).send({ error: 'Could not store the contract.' })
    }

    const { data: doc, error: docErr } = await db
      .from('documents')
      .insert({
        company_id: template.company_id,
        person_id: personId,
        category_key: template.category_key,
        title: `${template.title} (v${template.version})`,
        storage_path: path,
        visibility: 'person_and_hr',
        original_name: `${template.title}.pdf`,
        mime_type: 'application/pdf',
        size_bytes: pdf.length,
        uploaded_by: me?.id ?? null,
      })
      .select('id')
      .single()
    if (docErr) {
      // Leave no orphan file behind if the row could not be written.
      await db.storage.from(BUCKET).remove([path])
      req.log.error({ err: docErr.message }, 'contract document insert failed')
      return reply.code(500).send({ error: 'Could not file the contract.' })
    }

    return reply.send({ documentId: doc.id, title: template.title, version: template.version })
  })
}
