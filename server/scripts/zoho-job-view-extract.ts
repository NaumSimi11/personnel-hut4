#!/usr/bin/env npx tsx
/**
 * Read HR's Zoho Recruit "Candidate-Job View" CSV and write the import
 * payload (the SQL import function consumes it). Pure: no database, no
 * secrets. Prints counts, the by-status table and problems by Candidate ID
 * only — never a name or an email.
 *
 * Usage:
 *   npm run import:zoho-job-view:extract -- <csv> [--tz Europe/Skopje] [--out .zoho-job-view.json] [--skip-missing-id]
 *
 * Exits 1 on any problem: those are problems, never guesses.
 */
import fs from 'node:fs'
import path from 'node:path'
import { readCsv } from '../src/zohoRecruit/csv.js'
import { buildJobViewPayload } from '../src/zohoRecruit/jobView.js'

const USAGE = 'Usage: zoho-job-view-extract.ts <csv> [--tz Europe/Skopje] [--out .zoho-job-view.json] [--skip-missing-id]'
const TAG = '[zoho-job-view]'
const say = (line: string) => process.stdout.write(`${TAG} ${line}\n`)

function parseArgs(argv: string[]) {
  const positional = argv.filter((a, i) => !a.startsWith('--') && !(i > 0 && argv[i - 1].startsWith('--')))
  const flag = (name: string, fallback: string) => {
    const i = argv.indexOf(name)
    const next = i === -1 ? undefined : argv[i + 1]
    return next === undefined || next.startsWith('--') ? fallback : next
  }
  if (positional.length !== 1) throw new Error(USAGE)
  return {
    csv: positional[0],
    tz: flag('--tz', 'Europe/Skopje'),
    out: flag('--out', '.zoho-job-view.json'),
    skipMissingId: argv.includes('--skip-missing-id'),
  }
}

function main(): number {
  const args = parseArgs(process.argv.slice(2))
  const { payload, counts, problems } = buildJobViewPayload(readCsv(args.csv), { tz: args.tz, skipMissingId: args.skipMissingId })
  fs.writeFileSync(args.out, JSON.stringify({ ...payload, timezone_assumed: args.tz }))
  say(`wrote ${path.resolve(args.out)}`)
  say(`timezone_assumed: ${args.tz}`)
  say(`candidates: ${counts.candidates}`)
  say(`applications: ${counts.applications}`)
  say(`notes: ${counts.notes}`)
  say(`skipped (no Candidate ID): ${counts.skippedNoId}`)
  say('by status:')
  for (const [key, n] of Object.entries(counts.byStatus).sort((a, b) => b[1] - a[1])) say(`  ${key}: ${n}`)
  say(`problems: ${problems.length}`)
  for (const p of problems) say(`  ${p.ref}: ${p.message}`)
  return problems.length === 0 ? 0 : 1
}

try {
  process.exit(main())
} catch (e) {
  process.stderr.write(`${TAG} ${e instanceof Error ? e.message : String(e)}\n`)
  process.exit(1)
}
