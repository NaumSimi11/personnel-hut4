#!/usr/bin/env npx tsx
/**
 * Upload the Zoho Recruit attachments as candidate files (plan 052 §3.4).
 * Runs after a committed row import (scripts/zoho-import.sh --commit): every
 * manifest row needs its candidate in the database.
 *
 * Usage:
 *   npx tsx server/scripts/zoho-recruit-files.ts --dry-run [.zoho-files.json]
 *   npx tsx server/scripts/zoho-recruit-files.ts --commit  [.zoho-files.json]
 *
 * Idempotent: a row whose provider_ref already exists is skipped. Writes to
 * whatever SUPABASE_URL in .env.local names. Prints counts and the failures
 * list (attachment ids and errors) — never a candidate's name.
 */
import fs from 'node:fs'
import path from 'node:path'
import { randomUUID } from 'node:crypto'
import { fileURLToPath } from 'node:url'
import { createClient, type SupabaseClient } from '@supabase/supabase-js'
import { htmlToText, isGenericAccount, planUpload, type ManifestRow, type UploadPlan } from '../src/zohoRecruit/files.js'

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..')
const BUCKET = 'candidate-files'
const PROVIDER = 'zoho_recruit'
const CONCURRENCY = 4
const PAGE = 1000
const TZ = 'Europe/Skopje'
const TAG = '[zoho-files]'
const say = (line: string) => process.stdout.write(`${TAG} ${line}\n`)

function env(key: string): string {
  const raw = fs.readFileSync(path.join(REPO_ROOT, '.env.local'), 'utf8')
  const m = raw.match(new RegExp('^' + key + '=(.*)$', 'm'))
  return m ? m[1].trim().replace(/^"|"$/g, '') : ''
}

function db(): SupabaseClient {
  const url = env('SUPABASE_URL')
  const key = env('SUPABASE_SECRET_KEY')
  if (!url || !key) throw new Error('SUPABASE_URL / SUPABASE_SECRET_KEY missing from .env.local')
  return createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } })
}

/** Every row of a table, a page at a time (PostgREST caps a select at 1000). */
type Query = ReturnType<ReturnType<SupabaseClient['from']>['select']>

async function allRows<T>(client: SupabaseClient, table: string, columns: string, filter: (q: Query) => Query): Promise<T[]> {
  const rows: T[] = []
  for (let from = 0; ; from += PAGE) {
    const { data, error } = await filter(client.from(table).select(columns)).range(from, from + PAGE - 1)
    if (error) throw new Error(`${table}: ${error.message}`)
    rows.push(...((data ?? []) as T[]))
    if (!data || data.length < PAGE) return rows
  }
}

type Decision = { row: ManifestRow; plan: UploadPlan; uploadedBy: string | null } | { row: ManifestRow; skip: string }

async function decide(client: SupabaseClient, manifest: ManifestRow[]): Promise<Decision[]> {
  const candidates = await allRows<{ id: string; provider_ref: string }>(client, 'candidates', 'id, provider_ref', (q) => q.eq('provider', PROVIDER))
  const existing = await allRows<{ provider_ref: string }>(client, 'candidate_files', 'provider_ref', (q) => q.eq('provider', PROVIDER))
  const people = await allRows<{ id: string; work_email: string | null }>(client, 'people', 'id, work_email', (q) => q.is('archived_at', null).not('work_email', 'is', null))
  const candidateId = new Map(candidates.map((c) => [c.provider_ref, c.id]))
  const done = new Set(existing.map((f) => f.provider_ref))
  const personByEmail = new Map(people.map((p) => [(p.work_email ?? '').toLowerCase(), p.id]))
  say(`candidates known: ${candidateId.size} · files already imported: ${done.size}`)
  return manifest.map((row) => {
    if (done.has(row.attachment_id)) return { row, skip: 'already imported' }
    const id = candidateId.get(row.candidate_zoho_id)
    if (!id) return { row, skip: 'candidate not imported' }
    if (!fs.existsSync(row.path)) return { row, skip: 'not on disk' }
    // The rule pass 1 applies to its users: a generic account never names a person.
    const owner = row.owner_email && !isGenericAccount(row.owner_email) ? row.owner_email : null
    return { row, plan: planUpload(row, id, randomUUID(), TZ), uploadedBy: owner ? (personByEmail.get(owner) ?? null) : null }
  })
}

type Outcome = { attachment_id: string; ok: true } | { attachment_id: string; ok: false; error: string }

async function upload(client: SupabaseClient, d: Extract<Decision, { plan: UploadPlan }>): Promise<Outcome> {
  const { row, plan } = d
  try {
    const raw = fs.readFileSync(row.path)
    const text = plan.text_only ? htmlToText(raw.toString('utf8')) : null
    const body = text !== null ? Buffer.from(text, 'utf8') : raw
    const { error: uploadErr } = await client.storage.from(BUCKET).upload(plan.storage_path, body, { contentType: plan.mime_type, upsert: false })
    if (uploadErr) return { attachment_id: row.attachment_id, ok: false, error: `upload: ${uploadErr.message}` }
    const { error: rowErr } = await client.from('candidate_files').insert({
      id: plan.file_id,
      candidate_id: plan.candidate_id,
      kind: plan.kind,
      storage_path: plan.storage_path,
      original_name: plan.original_name,
      mime_type: plan.mime_type,
      size_bytes: body.length,
      uploaded_by: d.uploadedBy,
      extracted_text: text,
      provider: PROVIDER,
      provider_ref: plan.provider_ref,
      created_at: plan.created_at ?? undefined,
    })
    if (rowErr) {
      await client.storage.from(BUCKET).remove([plan.storage_path])
      return { attachment_id: row.attachment_id, ok: false, error: `row: ${rowErr.message}` }
    }
    return { attachment_id: row.attachment_id, ok: true }
  } catch (e) {
    return { attachment_id: row.attachment_id, ok: false, error: e instanceof Error ? e.message : String(e) }
  }
}

/** A fixed number of workers pulling from one queue, results in queue order. */
async function inParallel<T, R>(items: T[], workers: number, run: (item: T) => Promise<R>): Promise<R[]> {
  const results: R[] = new Array(items.length)
  let next = 0
  const worker = async () => {
    while (next < items.length) {
      const i = next++
      results[i] = await run(items[i])
    }
  }
  await Promise.all(Array.from({ length: Math.min(workers, items.length) }, worker))
  return results
}

function summarise(decisions: Decision[]): Record<string, number> {
  const skipped: Record<string, number> = {}
  for (const d of decisions) if ('skip' in d) skipped[d.skip] = (skipped[d.skip] ?? 0) + 1
  return skipped
}

async function main(): Promise<number> {
  const [, , mode, file] = process.argv
  if (mode !== '--dry-run' && mode !== '--commit') {
    process.stdout.write('Usage: zoho-recruit-files.ts --dry-run|--commit [.zoho-files.json]\n')
    return 1
  }
  const manifestPath = path.resolve(file ?? path.join(REPO_ROOT, '.zoho-files.json'))
  if (!fs.existsSync(manifestPath)) throw new Error(`manifest not found: ${manifestPath} (run npm run import:zoho-recruit:extract first)`)
  const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8')) as ManifestRow[]
  if (!Array.isArray(manifest)) throw new Error('the manifest must be an array')
  say(`manifest rows: ${manifest.length}`)

  const client = db()
  const decisions = await decide(client, manifest)
  const todo = decisions.filter((d): d is Extract<Decision, { plan: UploadPlan }> => 'plan' in d)
  const skipped = summarise(decisions)
  say(`to upload: ${todo.length} (text-only ${todo.filter((d) => d.plan.text_only).length}) · skipped: ${JSON.stringify(skipped)}`)
  if (mode === '--dry-run') {
    say('dry run: nothing uploaded')
    return 0
  }

  let done = 0
  const outcomes = await inParallel(todo, CONCURRENCY, async (d) => {
    const outcome = await upload(client, d)
    done += 1
    if (done % 100 === 0) say(`… ${done} of ${todo.length}`)
    return outcome
  })
  const failures = outcomes.filter((o): o is Extract<Outcome, { ok: false }> => !o.ok)
  say(`uploaded: ${outcomes.length - failures.length} · skipped: ${decisions.length - todo.length} · failed: ${failures.length}`)
  for (const f of failures) say(`   FAILED ${f.attachment_id}: ${f.error}`)
  return failures.length ? 1 : 0
}

main()
  .then((code) => process.exit(code))
  .catch((e) => {
    process.stderr.write(`${TAG} ${e instanceof Error ? e.message : String(e)}\n`)
    process.exit(1)
  })
