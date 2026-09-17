#!/usr/bin/env npx tsx
/**
 * Import the holding's equipment spreadsheet into the asset register.
 *
 * Two passes, on purpose. The first reads the workbook and writes a review
 * file saying how every row was understood, and changes nothing. A person
 * then corrects that file — above all the holders the resolver refused to
 * guess — and the second pass applies it.
 *
 * Usage:
 *   npx tsx server/scripts/import-popis-xlsx.ts read  <file.xlsx> [--out review.json]
 *   npx tsx server/scripts/import-popis-xlsx.ts apply <review.json> [--commit]
 *
 * `apply` is a dry run that prints what it would write unless --commit is
 * given. It writes to whatever SUPABASE_URL names, which is production.
 */
import fs from 'node:fs'
import path from 'node:path'
import zlib from 'node:zlib'
import { createClient } from '@supabase/supabase-js'
import { parseSheet, resolveHolder } from '../../shared/popisImport.js'
import { parseRowCells, unescapeXml } from '../src/popisXlsxCells.js'
import { assertUniqueAssetTags, summarizeWrites, writeSheets } from '../src/popisAssetWrite.js'
import { supabaseStore } from '../src/popisSupabaseStore.js'

// ----------------------------------------------------------------- xlsx

/** Entries of a ZIP, by name. An .xlsx is a ZIP of XML parts. */
function readZip(buf) {
  const files = {}
  // Walk the central directory from the end-of-central-directory record.
  let eocd = buf.length - 22
  while (eocd >= 0 && buf.readUInt32LE(eocd) !== 0x06054b50) eocd--
  if (eocd < 0) throw new Error('Not a zip file (no end-of-central-directory record)')
  const count = buf.readUInt16LE(eocd + 10)
  let p = buf.readUInt32LE(eocd + 16)
  for (let i = 0; i < count; i++) {
    const nameLen = buf.readUInt16LE(p + 28)
    const extraLen = buf.readUInt16LE(p + 30)
    const commentLen = buf.readUInt16LE(p + 32)
    const localOffset = buf.readUInt32LE(p + 42)
    const name = buf.toString('utf8', p + 46, p + 46 + nameLen)
    const method = buf.readUInt16LE(localOffset + 8)
    const compressed = buf.readUInt32LE(localOffset + 18)
    const lNameLen = buf.readUInt16LE(localOffset + 26)
    const lExtraLen = buf.readUInt16LE(localOffset + 28)
    const start = localOffset + 30 + lNameLen + lExtraLen
    const raw = buf.subarray(start, start + compressed)
    files[name] = method === 0 ? raw : zlib.inflateRawSync(raw)
    p += 46 + nameLen + extraLen + commentLen
  }
  return files
}

function sharedStrings(files) {
  const xml = files['xl/sharedStrings.xml']?.toString('utf8')
  if (!xml) return []
  return [...xml.matchAll(/<si>(.*?)<\/si>/gs)].map((m) =>
    [...m[1].matchAll(/<t[^>]*>(.*?)<\/t>/gs)].map((t) => unescapeXml(t[1])).join(''),
  )
}

function sheetNames(files) {
  const wb = files['xl/workbook.xml'].toString('utf8')
  return [...wb.matchAll(/<sheet[^>]*name="([^"]+)"/g)].map((m) => unescapeXml(m[1]))
}

/** Rows of one sheet as arrays of cell text, column position preserved. */
function sheetRows(files, index, strings) {
  const xml = files[`xl/worksheets/sheet${index + 1}.xml`].toString('utf8')
  return [...xml.matchAll(/<row[^>]*>(.*?)<\/row>/gs)].map((rowMatch) => ({
    cells: parseRowCells(rowMatch[1], strings),
  }))
}

// ----------------------------------------------------------------- passes

const REPO_ROOT = path.resolve(new URL('../..', import.meta.url).pathname)

function env(key) {
  const raw = fs.readFileSync(path.join(REPO_ROOT, '.env.local'), 'utf8')
  const m = raw.match(new RegExp('^' + key + '=(.*)$', 'm'))
  return m ? m[1].trim() : ''
}

function db() {
  const url = env('SUPABASE_URL')
  const key = env('SUPABASE_SECRET_KEY')
  if (!url || !key) throw new Error('SUPABASE_URL / SUPABASE_SECRET_KEY missing from .env.local')
  return createClient(url, key, { auth: { persistSession: false, autoRefreshToken: false } })
}

async function read(file, out) {
  const files = readZip(fs.readFileSync(file))
  const strings = sharedStrings(files)
  const names = sheetNames(files)

  const client = db()
  const [{ data: people }, { data: companies }] = await Promise.all([
    client.from('people').select('id, full_name'),
    client.from('companies').select('id, name'),
  ])

  const sheets = names.map((name, i) => {
    const items = parseSheet(sheetRows(files, i, strings))
    const company = companies.find(
      (c) => c.name.toLowerCase().replace(/\s+/g, '') === name.toLowerCase().replace(/\s+/g, ''),
    )
    return {
      sheet: name,
      companyId: company ? company.id : null,
      companyName: company ? company.name : null,
      items: items.map((item) => ({ ...item, holder: resolveHolder(item.holderText, people) })),
    }
  })

  fs.writeFileSync(out, JSON.stringify({ source: file, readAt: new Date().toISOString(), sheets }, null, 2))

  for (const s of sheets) {
    const unresolved = s.items.filter((i) => i.holder.kind === 'unresolved')
    process.stdout.write(
      `${s.sheet}: ${s.items.length} items → ${s.companyName ?? 'NO COMPANY MATCHED'}, ` +
      `${unresolved.length} holder(s) need a human\n`,
    )
    for (const u of unresolved) {
      process.stdout.write(`    ${u.assetTag ?? '(no tag)'} ${u.model} → "${u.holder.text}" (${u.holder.reason})\n`)
    }
  }
  process.stdout.write(`\nReview file written to ${out}. Correct it, then run "apply".\n`)
}

/** The asset row and holder one reviewed sheet item imports as. */
function toWriteItem(source, sheet, item, index) {
  // A sheet row without a code still needs a unique tag within its company.
  // This generated tag is also what makes a re-run resumable (see
  // popisAssetWrite.ts): it is only stable while this same review file is
  // reused unedited — reordering or adding items renumbers it, and the
  // re-run would then create duplicates instead of reconciling.
  const tag = item.assetTag ?? `${sheet.sheet.replace(/\s+/g, '').toUpperCase()}-${String(index + 1).padStart(4, '0')}`
  const noteParts = []
  if (item.holder.kind === 'person' && item.holder.atCompany) noteParts.push(`Used at ${item.holder.atCompany}`)
  if (item.note) noteParts.push(item.note)
  noteParts.push(`Imported from ${path.basename(source)} (${sheet.sheet})`)

  // Whoever the sheet names, when that is not a person in this system. Without
  // it the register showed the asset sitting in magacin, free to hand out,
  // while the books said someone had it — a worse answer than saying nothing.
  const holderNote =
    item.holder.kind === 'company' ? item.holder.text
    : item.holder.kind === 'unresolved' ? item.holder.text
    : null

  return {
    asset: {
      company_id: sheet.companyId,
      asset_tag: tag,
      type_key: item.typeKey,
      model: item.model,
      note: noteParts.join(' · ').slice(0, 500),
      inventory_number: item.inventoryNumber ?? null,
      holder_note: holderNote,
    },
    personId: item.holder.kind === 'person' ? item.holder.personId : null,
  }
}

/** Prints what one committed row did, so an interrupted run still has a record of it. */
function reportRow({ sheet, tag, result }) {
  const detail = result.outcome === 'failed' ? `: ${result.message}` : result.warning ? ` but ${result.warning}` : ''
  const outcome = result.outcome === 'failed' ? 'FAILED' : result.outcome
  const held = result.outcome !== 'failed' && result.assigned ? 'assigned' : 'available'
  process.stdout.write(`${outcome} ${sheet} ${tag} (${held})${detail}\n`)
}

async function apply(reviewFile, commit) {
  const review = JSON.parse(fs.readFileSync(reviewFile, 'utf8'))

  const unresolved = review.sheets.flatMap((s) => s.items.filter((i) => i.holder.kind === 'unresolved'))
  if (unresolved.length) {
    process.stdout.write(`${unresolved.length} holder(s) are still unresolved; they import unassigned with the original text kept in the note.\n`)
  }
  const noCompany = review.sheets.filter((s) => !s.companyId)
  if (noCompany.length) {
    throw new Error(`Refusing: no company matched for sheet(s) ${noCompany.map((s) => s.sheet).join(', ')}. Fix companyId in the review file.`)
  }

  const sheets = review.sheets.map((sheet) => ({
    sheet: sheet.sheet,
    items: sheet.items.map((item, index) => toWriteItem(review.source, sheet, item, index)),
  }))
  // The dry run refuses for the same reason the real one would, so the two
  // passes agree on what is importable before anybody types --commit.
  assertUniqueAssetTags(sheets)

  let results
  if (commit) {
    results = await writeSheets(supabaseStore(db()), sheets, reportRow)
  } else {
    results = sheets.flatMap((sheet) =>
      sheet.items.map(({ asset, personId }) => {
        process.stdout.write(`would create ${sheet.sheet} ${asset.asset_tag} ${asset.type_key} "${asset.model}" (${personId ? 'assigned' : 'available'})\n`)
        return { outcome: 'created', assigned: personId !== null }
      }),
    )
  }

  const summary = summarizeWrites(results)
  const outcomes = commit ? `, reconciled ${summary.reconciled}, failed ${summary.failed}` : ''
  process.stdout.write(
    `\n${commit ? 'Created' : 'Would create'} ${summary.created} assets${outcomes}, ${summary.assigned} assigned to a person.\n`,
  )
}

const [, , mode, file, ...rest] = process.argv
const flag = (name, fallback) => {
  const i = rest.indexOf(name)
  return i === -1 ? fallback : rest[i + 1]
}

if (mode === 'read') {
  if (!file) throw new Error('Usage: import-popis-xlsx.ts read <file.xlsx> [--out review.json]')
  await read(file, flag('--out', 'popis-import-review.json'))
} else if (mode === 'apply') {
  if (!file) throw new Error('Usage: import-popis-xlsx.ts apply <review.json> [--commit]')
  await apply(file, rest.includes('--commit'))
} else {
  process.stdout.write('Usage:\n  import-popis-xlsx.ts read  <file.xlsx> [--out review.json]\n  import-popis-xlsx.ts apply <review.json> [--commit]\n')
  process.exit(1)
}
