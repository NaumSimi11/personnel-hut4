/**
 * Telling a stale build apart from a real error.
 *
 * Every deploy writes new hashed chunk filenames. A tab left open still holds
 * the previous index.html, so the next route it lazily loads asks for a file
 * that is no longer there — and because the SPA rewrite answers anything that
 * is not /api with index.html, the browser gets HTML where it expected
 * JavaScript and refuses it on MIME grounds. The page then simply does not
 * navigate, which reads as the app being broken.
 *
 * The cure is a full page load: it fetches the current index.html and with it
 * the chunk names that actually exist. The judgement is only ever "is this that
 * situation", because reloading on an ordinary error would hide real bugs and
 * could loop.
 */
const STALE = [
  /failed to fetch dynamically imported module/i,
  /error loading dynamically imported module/i,
  /importing a module script failed/i,
  /expected a javascript-or-wasm module script/i,
  /failed to load module script/i,
]

export function isStaleBuildError(error: unknown): boolean {
  const message = error instanceof Error ? error.message : ''
  return message !== '' && STALE.some((pattern) => pattern.test(message))
}
