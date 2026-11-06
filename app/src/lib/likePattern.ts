/** A contains-pattern for `ilike`: the typed text with LIKE's own wildcards made literal. */
export function likePattern(term: string): string {
  return `%${term.trim().replace(/[\\%_]/g, (c) => `\\${c}`)}%`
}
