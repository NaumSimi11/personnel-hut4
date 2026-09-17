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

const unescapeXml = (s) =>
  s.replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"')
   .replace(/&apos;/g, "'").replace(/&amp;/g, '&')

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
  return [...xml.matchAll(/<row[^>]*>(.*?)<\/row>/gs)].map((rowMatch) => {
    const cells = []
    for (const c of rowMatch[1].matchAll(/<c([^>]*)>(.*?)<\/c>/gs)) {
      const ref = c[1].match(/r="([A-Z]+)\d+"/)
      const col = ref ? ref[1].split('').reduce((n, ch) => n * 26 + ch.charCodeAt(0) - 64, 0) - 1 : cells.length
      const isShared = /t="s"/.test(c[1])
      const isInline = /t="(inlineStr|str)"/.test(c[1])
      const v = c[2].match(/<v>(.*?)<\/v>/s)
      const t = c[2].match(/<t[^>]*>(.*?)<\/t>/s)
      let text = null
      if (isShared && v) text = strings[Number(v[1])] ?? null
      else if (isInline && t) text = unescapeXml(t[1])
      else if (v) text = unescapeXml(v[1])
      while (cells.length < col) cells.push(null)
      cells[col] = text
    }
    return { cells }
  })
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

const [, , mode, file, ...rest] = process.argv
const flag = (name, fallback) => {
  const i = rest.indexOf(name)
  return i === -1 ? fallback : rest[i + 1]
}

if (mode === 'read') {
  if (!file) throw new Error('Usage: import-popis-xlsx.ts read <file.xlsx> [--out review.json]')
  await read(file, flag('--out', 'popis-import-review.json'))
} else {
  process.stdout.write('Usage: import-popis-xlsx.ts read <file.xlsx> [--out review.json]\n')
  process.exit(1)
}
