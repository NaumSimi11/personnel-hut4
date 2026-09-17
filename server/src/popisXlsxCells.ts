/**
 * Reading one <row>'s cells out of raw worksheet XML.
 *
 * Pulled out of `scripts/import-popis-xlsx.ts` so the reader has a test that
 * does not require a real .xlsx file. A cell is either self-closing
 * (`<c r="B1" s="1"/>`, meaning empty) or paired (`<c ...>...</c>`) — the
 * regex has to tell those apart without letting the closing `/` of a
 * self-closing cell's attributes be mistaken for the start of a body. Get
 * that wrong and a self-closing cell swallows the *next* cell whole: the
 * value lands under the wrong column reference, and the wrong cell's
 * attributes are consulted, so a shared-string lookup silently degrades
 * into the literal string index.
 */

export const unescapeXml = (s: string): string =>
  s.replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&quot;/g, '"')
   .replace(/&apos;/g, "'").replace(/&amp;/g, '&')

/** Cell values of one row, in column order (a skipped column reads as null). */
export function parseRowCells(rowInner: string, strings: readonly string[]): (string | null)[] {
  const cells: (string | null)[] = []
  // `(?:\/>|>([\s\S]*?)<\/c>)` — try the self-closing form first, so its `/`
  // can never be captured as the start of a body. Only when that fails does
  // the paired form get to consume up to the matching `</c>`.
  for (const c of rowInner.matchAll(/<c([^>]*?)(?:\/>|>([\s\S]*?)<\/c>)/g)) {
    const attrs = c[1]
    const body = c[2] ?? ''
    const ref = attrs.match(/r="([A-Z]+)\d+"/)
    const col = ref ? ref[1].split('').reduce((n, ch) => n * 26 + ch.charCodeAt(0) - 64, 0) - 1 : cells.length
    const isShared = /t="s"/.test(attrs)
    const isInline = /t="(inlineStr|str)"/.test(attrs)
    const v = body.match(/<v>(.*?)<\/v>/s)
    const t = body.match(/<t[^>]*>(.*?)<\/t>/s)
    let text: string | null = null
    if (isShared && v) text = strings[Number(v[1])] ?? null
    else if (isInline && t) text = unescapeXml(t[1])
    else if (v) text = unescapeXml(v[1])
    while (cells.length < col) cells.push(null)
    cells[col] = text
  }
  return cells
}
