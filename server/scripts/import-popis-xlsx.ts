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

async function apply(reviewFile, commit) {
  const review = JSON.parse(fs.readFileSync(reviewFile, 'utf8'))
  const client = db()

  const unresolved = review.sheets.flatMap((s) => s.items.filter((i) => i.holder.kind === 'unresolved'))
  if (unresolved.length) {
    process.stdout.write(`${unresolved.length} holder(s) are still unresolved; they import unassigned with the original text kept in the note.\n`)
  }
  const noCompany = review.sheets.filter((s) => !s.companyId)
  if (noCompany.length) {
    throw new Error(`Refusing: no company matched for sheet(s) ${noCompany.map((s) => s.sheet).join(', ')}. Fix companyId in the review file.`)
  }

  let created = 0
  let assigned = 0
  for (const sheet of review.sheets) {
    for (const [index, item] of sheet.items.entries()) {
      // A sheet row without a code still needs a unique tag within its company.
      const tag = item.assetTag ?? `${sheet.sheet.replace(/\s+/g, '').toUpperCase()}-${String(index + 1).padStart(4, '0')}`
      const noteParts = []
      if (item.holder.kind === 'company') noteParts.push(`Held by ${item.holder.text}`)
      if (item.holder.kind === 'unresolved') noteParts.push(`Holder from spreadsheet: "${item.holder.text}" (${item.holder.reason})`)
      if (item.holder.kind === 'person' && item.holder.atCompany) noteParts.push(`Used at ${item.holder.atCompany}`)
      noteParts.push(`Imported from ${path.basename(review.source)} (${sheet.sheet})`)

      const row = {
        company_id: sheet.companyId,
        asset_tag: tag,
        type_key: item.typeKey,
        model: item.model,
        status: item.holder.kind === 'person' ? 'assigned' : 'available',
        note: noteParts.join(' · ').slice(0, 500),
      }
      if (!commit) {
        process.stdout.write(`would create ${sheet.sheet} ${row.asset_tag} ${row.type_key} "${row.model}" (${row.status})\n`)
        created++
        if (item.holder.kind === 'person') assigned++
        continue
      }
      const { data: asset, error } = await client.from('assets').insert(row).select('id').single()
      if (error) {
        process.stdout.write(`FAILED ${sheet.sheet} ${row.asset_tag}: ${error.message}\n`)
        continue
      }
      created++
      if (item.holder.kind === 'person') {
        const { error: aErr } = await client.from('asset_assignments').insert({
          asset_id: asset.id,
          person_id: item.holder.personId,
          issued_at: new Date().toISOString(),
        })
        if (aErr) process.stdout.write(`FAILED assignment ${row.asset_tag}: ${aErr.message}\n`)
        else assigned++
      }
    }
  }
  process.stdout.write(`\n${commit ? 'Created' : 'Would create'} ${created} assets, ${assigned} assigned to a person.\n`)
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
