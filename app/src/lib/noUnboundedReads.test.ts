import { describe, expect, it } from 'vitest'

/**
 * The project is on a metered plan: a read of a growing table with no bound
 * is what drains the monthly egress. Every select on these tables must page
 * (.range / .limit), read one row (.single / .maybeSingle, or an id filter on
 * a single row), or only count (head: true). `// bounded: <reason>` on the
 * `.from(` line exempts a chain that is bounded some other way.
 */
const TABLES = ['applications', 'candidates', 'application_events', 'candidate_notes']
const WINDOW = 400
const BOUNDS = [
  '.range(',
  '.limit(',
  '.single(',
  '.maybeSingle(',
  'head: true',
  ".eq('id'",
  ".eq('candidate_id'",
  ".eq('application_id'",
]

// Every source file's text, read by Vite (no node typings in this project).
const FILES = import.meta.glob<string>(['../**/*.ts', '../**/*.vue', '!../**/*.test.ts'], {
  query: '?raw',
  import: 'default',
  eager: true,
})

export function unboundedReads(text: string, file: string): string[] {
  const found: string[] = []
  const pattern = new RegExp(`\\.from\\('(${TABLES.join('|')})'\\)`, 'g')
  for (const match of text.matchAll(pattern)) {
    const start = match.index ?? 0
    const lineEnd = text.indexOf('\n', start)
    const line = text.slice(start, lineEnd === -1 ? undefined : lineEnd)
    if (/\/\/\s*bounded:/.test(line)) continue
    const chain = text.slice(start, start + WINDOW)
    if (!chain.includes('.select(')) continue
    if (BOUNDS.some((b) => chain.includes(b))) continue
    const lineNo = text.slice(0, start).split('\n').length
    found.push(`${file}:${lineNo}`)
  }
  return found
}

describe('no unbounded reads', () => {
  it('flags a select with no bound', () => {
    expect(unboundedReads("supabase.from('applications').select('id')", 'x.ts')).toEqual(['x.ts:1'])
  })
  it('accepts a bound or a bounded: comment', () => {
    expect(unboundedReads("supabase.from('applications').select('id').range(0, 49)", 'x.ts')).toEqual([])
    expect(unboundedReads("supabase.from('applications') // bounded: one job\n  .select('id')", 'x.ts')).toEqual([])
  })
  it('finds none in the app source', () => {
    const offenders = Object.entries(FILES).flatMap(([file, text]) => unboundedReads(text, file.replace('../', '')))
    expect(Object.keys(FILES).length).toBeGreaterThan(50)
    expect(offenders).toEqual([])
  })
})
