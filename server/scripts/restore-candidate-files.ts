#!/usr/bin/env npx tsx
/**
 * Re-attach the candidate files of the 2026-11-05 backup to the candidates the
 * Zoho import re-created, matched by Zoho Candidate ID. Run after the committed
 * job-view import.
 *
 * Usage:
 *   npx tsx server/scripts/restore-candidate-files.ts --dry-run <backupDir>
 *   RESTORE_ALLOW_PRODUCTION=true npx tsx server/scripts/restore-candidate-files.ts --commit <backupDir>
 *
 * Idempotent: a file id already in candidate_files is skipped; a storage object
 * that already exists counts as uploaded. Prints the target host (never keys),
 * counts and failures by file id — never a name.
 */
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { createClient, type SupabaseClient } from '@supabase/supabase-js'
import { readCsv } from '../src/zohoRecruit/csv.js'
import { planRestore, type RestoreUpload } from '../src/zohoRecruit/restoreFiles.js'

const REPO_ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..')
const BUCKET = 'candidate-files'
const PROVIDER = 'zoho_recruit'
const CONCURRENCY = 4
const PAGE = 1000
const TAG = '[restore-files]'
const say = (line: string) => process.stdout.write(`${TAG} ${line}\n`)

function env(key: string): string {
  const raw = fs.readFileSync(path.join(REPO_ROOT, '.env.local'), 'utf8')
  const m = raw.match(new RegExp('^' + key + '=(.*)$', 'm'))
  return m ? m[1].trim().replace(/^"|"$/g, '') : ''
}

function db(url: string): SupabaseClient {
  const key = env('SUPABASE_SECRET_KEY')
  if (!key) throw new Error('SUPABASE_SECRET_KEY missing from .env.local')
  return createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } })
}

/** Every row of a table in a stable order, a page of 1000 at a time. */
async function pagedRows<T>(client: SupabaseClient, table: string, columns: string, orderBy: string, eq?: [string, string]): Promise<T[]> {
  const rows: T[] = []
  for (let from = 0; ; from += PAGE) {
    let q = client.from(table).select(columns)
    if (eq) q = q.eq(eq[0], eq[1])
    const { data, error } = await q.order(orderBy, { ascending: true }).range(from, from + PAGE - 1)
    if (error) throw new Error(`${table}: ${error.message}`)
    rows.push(...((data ?? []) as T[]))
    if (!data || data.length < PAGE) return rows
  }
}

type Outcome = { fileId: string; ok: true } | { fileId: string; ok: false; error: string }

const alreadyExists = (e: { message: string; statusCode?: string | number }) =>
  String(e.statusCode) === '409' || /already exists/i.test(e.message)

async function restoreOne(client: SupabaseClient, filesDir: string, u: RestoreUpload): Promise<Outcome> {
  try {
    const source = path.resolve(filesDir, u.from)
    if (!source.startsWith(filesDir + path.sep)) return { fileId: u.fileId, ok: false, error: 'source outside the backup files directory' }
    if (!fs.existsSync(source)) return { fileId: u.fileId, ok: false, error: 'not in the backup' }
    const { error: uploadErr } = await client.storage
      .from(BUCKET)
      .upload(u.to, fs.readFileSync(source), { contentType: String(u.row.mime_type), upsert: false })
    if (uploadErr && !alreadyExists(uploadErr)) return { fileId: u.fileId, ok: false, error: `upload: ${uploadErr.message}` }
    const { error: rowErr } = await client.from('candidate_files').insert(u.row)
    if (rowErr) return { fileId: u.fileId, ok: false, error: `row: ${rowErr.message}` }
    return { fileId: u.fileId, ok: true }
  } catch (e) {
    return { fileId: u.fileId, ok: false, error: e instanceof Error ? e.message : String(e) }
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

function countBy(reasons: string[]): Record<string, number> {
  const out: Record<string, number> = {}
  for (const r of reasons) out[r] = (out[r] ?? 0) + 1
  return out
}

async function main(): Promise<number> {
  const [, , mode, backupArg] = process.argv
  if ((mode !== '--dry-run' && mode !== '--commit') || !backupArg) {
    process.stdout.write('Usage: restore-candidate-files.ts --dry-run|--commit <backupDir>\n')
    return 1
  }
  const url = env('SUPABASE_URL')
  if (!url) throw new Error('SUPABASE_URL missing from .env.local')
  say(`target: ${new URL(url).host} (${mode})`)
  if (mode === '--commit' && process.env.RESTORE_ALLOW_PRODUCTION !== 'true') {
    throw new Error('refusing to --commit: set RESTORE_ALLOW_PRODUCTION=true to write to this target')
  }

  const backupDir = path.resolve(backupArg)
  const filesDir = path.join(backupDir, 'files')
  const oldCandidates = readCsv(path.join(backupDir, 'db', 'candidates.csv'))
  const oldFiles = readCsv(path.join(backupDir, 'db', 'candidate_files.csv'))
  say(`backup: ${oldCandidates.length} candidates · ${oldFiles.length} files`)

  const client = db(url)
  const current = await pagedRows<{ id: string; provider_ref: string }>(client, 'candidates', 'id, provider_ref', 'id', ['provider', PROVIDER])
  const newIdByRef = new Map(current.map((c) => [c.provider_ref, c.id]))
  const present = await pagedRows<{ id: string }>(client, 'candidate_files', 'id', 'id')
  const presentIds = new Set(present.map((f) => f.id))
  say(`candidates re-imported: ${newIdByRef.size} · files already attached: ${presentIds.size}`)

  const plan = planRestore(oldCandidates, oldFiles, newIdByRef)
  const todo = plan.uploads.filter((u) => !presentIds.has(u.fileId))
  say(`to restore: ${todo.length} · already attached: ${plan.uploads.length - todo.length} · skipped: ${JSON.stringify(countBy(plan.skipped.map((s) => s.reason)))}`)
  if (mode === '--dry-run') {
    say('dry run: nothing written')
    return 0
  }

  let done = 0
  const outcomes = await inParallel(todo, CONCURRENCY, async (u) => {
    const outcome = await restoreOne(client, filesDir, u)
    done += 1
    if (done % 100 === 0) say(`… ${done} of ${todo.length}`)
    return outcome
  })
  const failures = outcomes.filter((o): o is Extract<Outcome, { ok: false }> => !o.ok)
  say(`restored: ${outcomes.length - failures.length} · failed: ${failures.length}`)
  for (const f of failures) say(`   FAILED ${f.fileId}: ${f.error}`)
  return failures.length ? 1 : 0
}

main()
  .then((code) => process.exit(code))
  .catch((e) => {
    process.stderr.write(`${TAG} ${e instanceof Error ? e.message : String(e)}\n`)
    process.exit(1)
  })
