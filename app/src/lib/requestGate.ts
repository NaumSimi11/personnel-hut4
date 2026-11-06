/**
 * A generation counter for overlapping reads. `next()` starts a request and
 * returns its ticket; `isCurrent(ticket)` is false once a newer request began
 * (or `invalidate()` ran); `snapshot()` tags a request that extends the
 * current list (load more) without retiring the one that built it, so a slow answer to an old filter is dropped
 * instead of overwriting or extending the list the user now sees.
 */
export function createRequestGate(): {
  next: () => number
  snapshot: () => number
  isCurrent: (ticket: number) => boolean
  invalidate: () => void
} {
  let generation = 0
  return {
    next: () => ++generation,
    snapshot: () => generation,
    isCurrent: (ticket) => ticket === generation,
    invalidate: () => {
      generation += 1
    },
  }
}
