/**
 * A job title is not free text for long: it reaches the employment agreement,
 * the handover to the accountant and the welcome note. "dvsdv" has already
 * made it into a live hiring request, so a length check alone is not enough.
 *
 * The rule stays deliberately shy, because rejecting a real title is worse
 * than admitting a bad one. It asks only that the title contain a letter and,
 * once it is long enough for the question to be fair, a vowel — which is what
 * separates a word from a mash of the home row. Short abbreviations (QA, CTO)
 * are exempt for exactly that reason.
 */
const VOWELS = /[aeiouyàáâäãåæèéêëìíîïòóôöõøùúûüαεηιουωаеиоуѐѝјрАЕИОУЈР]/i
const LETTER = /\p{L}/u
const MIN_LENGTH = 2
/** Below this, a title is an abbreviation and is not asked for a vowel. */
const VOWEL_EXEMPT_UP_TO = 3
/** A run straight off one row of the keyboard is a mash, vowels or not. */
const KEYBOARD_ROWS = ['qwertyuiop', 'asdfghjkl', 'zxcvbnm']
const MIN_KEYBOARD_RUN = 4

function isKeyboardRun(title: string): boolean {
  const letters = title.toLowerCase().replace(/[^a-z]/g, '')
  if (letters.length < MIN_KEYBOARD_RUN) return false
  return KEYBOARD_ROWS.some((row) => row.includes(letters))
}

export function cleanJobTitle(raw: string): string {
  return raw.trim().replace(/\s+/g, ' ')
}

export function jobTitleProblem(raw: string): string | null {
  const title = cleanJobTitle(raw)
  if (title.length < MIN_LENGTH) return 'Enter a job title.'
  if (!LETTER.test(title)) return 'A job title needs at least one letter.'

  const repeated = [...title].every((c) => c === title[0])
  if (repeated) return 'That does not look like a job title.'

  if (isKeyboardRun(title)) return 'That does not look like a job title.'

  if (title.length > VOWEL_EXEMPT_UP_TO && !VOWELS.test(title)) {
    return 'That does not look like a job title.'
  }
  return null
}
