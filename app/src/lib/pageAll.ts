/**
 * Paging past PostgREST's 1,000-row cap (plan 054 review).
 *
 * PostgREST answers at most 1,000 rows per request, so a plain `select()`
 * over a table the size of `applications` (several thousand rows since the
 * Zoho import, 0067) silently returns a prefix and every count taken from it
 * reads low. `pageAll` asks for the same query in `.range()` windows until a
 * short page proves the end, and stops at `maxPages` so a backend that keeps
 * answering full pages can never spin forever.
 *
 * The caller supplies the query with the window applied; order the query by a
 * stable column (an id), otherwise a page boundary can skip or repeat a row.
 */

/** PostgREST's per-request cap, and so the window size. */
export const PAGE_SIZE = 1000

/** At most five windows: 5,000 rows, well past any live list this app pages. */
export const MAX_PAGES = 5

/** What a supabase-js query resolves to, narrowed to what paging needs. */
export type PageResult<T> = { data: T[] | null; error: { message: string } | null }

export type PageAllOptions = {
  /** Rows per window. Defaults to PostgREST's cap. */
  pageSize?: number
  /** How many windows to ask for at most. Defaults to `MAX_PAGES`. */
  maxPages?: number
}

/**
 * Collect every row of a query, one window at a time.
 *
 * `fetchPage(from, to)` runs the query for one inclusive `.range(from, to)`
 * window. The first error aborts and is returned with no rows, as a single
 * unpaged query would have. A window shorter than `pageSize` ends the walk.
 */
export async function pageAll<T>(
  fetchPage: (from: number, to: number) => PromiseLike<PageResult<T>>,
  options: PageAllOptions = {},
): Promise<{ data: T[]; error: { message: string } | null }> {
  const pageSize = options.pageSize ?? PAGE_SIZE
  const maxPages = options.maxPages ?? MAX_PAGES
  const rows: T[] = []
  for (let page = 0; page < maxPages; page += 1) {
    const from = page * pageSize
    const { data, error } = await fetchPage(from, from + pageSize - 1)
    if (error) return { data: [], error }
    const chunk = data ?? []
    rows.push(...chunk)
    if (chunk.length < pageSize) break
  }
  return { data: rows, error: null }
}
