#!/usr/bin/env npx tsx
/**
 * Read the Zoho Recruit export and write the import_zoho_recruit payload,
 * the files manifest and the review file (plan 052 §3.2), or — with
 * --history — the import_zoho_history payload (plan 055 §3). Pure: no
 * database, no secrets. Prints counts only — never a name or an email.
 *
 * Usage:
 *   npx tsx server/scripts/zoho-recruit-extract.ts <data dir> <attachments dir>
 *     --tz Europe/Skopje --out .zoho-payload.json --files .zoho-files.json --review .zoho-review.json
 *   npx tsx server/scripts/zoho-recruit-extract.ts <data dir> --history .zoho-history.json --tz Europe/Skopje
 *
 * Exits 1 on an unknown status or source, and on a history problem: those
 * are problems, never guesses.
 */
import fs from 'node:fs'
import path from 'node:path'
import { readExport } from '../src/zohoRecruit/csv.js'
import { buildFilesManifest } from '../src/zohoRecruit/files.js'
import { buildHistory, readHistoryExport } from '../src/zohoRecruit/history.js'
import { buildPayload } from '../src/zohoRecruit/payload.js'

const USAGE = [
  'Usage: zoho-recruit-extract.ts <data dir> <attachments dir> [--tz Europe/Skopje] [--out .zoho-payload.json] [--files .zoho-files.json] [--review .zoho-review.json]',
  '   or: zoho-recruit-extract.ts <data dir> --history [.zoho-history.json] [--tz Europe/Skopje]',
].join('\n')

function parseArgs(argv: string[]) {
  const positional = argv.filter((a, i) => !a.startsWith('--') && !(i > 0 && argv[i - 1].startsWith('--')))
  const flag = (name: string, fallback: string) => {
    const i = argv.indexOf(name)
    const next = i === -1 ? undefined : argv[i + 1]
    return next === undefined || next.startsWith('--') ? fallback : next
  }
  const history = argv.includes('--history')
  if (positional.length !== (history ? 1 : 2)) throw new Error(USAGE)
  return {
    history,
    dataDir: positional[0],
    attachmentsDir: history ? null : positional[1],
    tz: flag('--tz', 'Europe/Skopje'),
    out: flag('--out', '.zoho-payload.json'),
    files: flag('--files', '.zoho-files.json'),
    review: flag('--review', '.zoho-review.json'),
    historyOut: flag('--history', '.zoho-history.json'),
  }
}

const TAG = '[zoho-extract]'
const say = (line: string) => process.stdout.write(`${TAG} ${line}\n`)

/** Plan 055 §3: the candidate notes, the interviews and the reviews as one payload. */
function history(args: ReturnType<typeof parseArgs>): number {
  const { payload, counts, problems } = buildHistory(readHistoryExport(args.dataDir), { tz: args.tz })
  fs.writeFileSync(args.historyOut, JSON.stringify(payload))
  say(`wrote ${path.resolve(args.historyOut)}`)
  say(`timezone_assumed: ${args.tz}`)
  say(`users: ${counts.users}`)
  say(`candidate notes: ${JSON.stringify(counts.notes)}`)
  say(`interviews: ${payload.interviews.length} ${JSON.stringify(counts.interviews)}`)
  say(`reviews: ${payload.reviews.length} ${JSON.stringify(counts.reviews)}`)
  say(`problems: ${counts.problems}`)
  // Refs and messages only — a problem never carries a name or a body.
  for (const p of problems) say(`problem: ${p.kind} ${p.ref} — ${p.message}`)
  if (problems.length) {
    process.stderr.write(`${TAG} problems in the history export: fix them before importing.\n`)
    return 1
  }
  return 0
}

function main(): number {
  const args = parseArgs(process.argv.slice(2))
  for (const dir of [args.dataDir, args.attachmentsDir]) {
    if (dir === null) continue
    if (!fs.existsSync(dir) || !fs.statSync(dir).isDirectory()) throw new Error(`Not a directory: ${dir}`)
  }
  if (args.history) return history(args)
  const exp = readExport(args.dataDir)
  const { payload, review, counts, unknown } = buildPayload(exp, { tz: args.tz, exportedAt: new Date().toISOString() })
  const files = buildFilesManifest(exp, args.attachmentsDir as string, args.tz)

  fs.writeFileSync(args.out, JSON.stringify(payload))
  fs.writeFileSync(args.files, JSON.stringify(files.manifest))
  fs.writeFileSync(args.review, JSON.stringify({ ...review, unresolvable_files: files.unresolvable, files_skipped: files.skipped }, null, 2))

  say(`wrote ${path.resolve(args.out)}, ${path.resolve(args.files)}, ${path.resolve(args.review)}`)
  say(`timezone_assumed: ${payload.timezone_assumed}`)
  say(`users: ${payload.users.length}`)
  say(`candidates: ${counts.candidates}`)
  say(`applications: ${JSON.stringify(counts.applications)}`)
  say(`do_not_contact: ${counts.do_not_contact} · contact_later: ${counts.contact_later}`)
  say(`jobs per company: ${JSON.stringify(counts.jobs)} · unresolved departments: ${counts.unresolved_departments}`)
  say(`notes: ${JSON.stringify(counts.notes)}`)
  say(`files: eligible ${files.counts.eligible} · text-only ${files.counts.text_only} · skipped ${files.counts.skipped} ${JSON.stringify(files.skipped)}`)
  say(`review: same-LinkedIn groups ${review.same_linkedin_by_key.length} by key / ${review.same_linkedin_by_url.length} by URL · same-name groups ${review.same_name_groups.length} · never associated ${review.never_associated.length} · stale ${review.stale_applications.length} · hires ${review.hires.length} · synthesised reasons ${review.synthesised_reasons.length} · problems ${review.problems.length}`)
  say(`unknown statuses: ${JSON.stringify(unknown.statuses)} · unknown sources: ${JSON.stringify(unknown.sources)}`)
  if (unknown.statuses.length || unknown.sources.length) {
    process.stderr.write(`${TAG} unknown statuses or sources: fix mapping.ts before importing.\n`)
    return 1
  }
  return 0
}

try {
  process.exit(main())
} catch (e) {
  process.stderr.write(`${TAG} ${e instanceof Error ? e.message : String(e)}\n`)
  process.exit(1)
}
