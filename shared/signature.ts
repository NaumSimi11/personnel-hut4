/**
 * A signature made in the app, and the sentence it is attached to.
 *
 * Shared because both ends need the same answer: the page decides whether to
 * enable the button, and the server decides whether to record the signature.
 * If they disagreed, one of them would be wrong about what counts.
 *
 * The cursive image is the least of it. What a signature has to survive is
 * someone later asking "did they agree to this, and to what exactly" — so the
 * statement is stored with the signature rather than assumed from the template,
 * which can be edited afterwards.
 */
export type SignatureMethod = 'typed' | 'drawn'

export type SignatureInput = {
  readonly method: SignatureMethod
  /** As typed. For a drawn signature, still required — the printed name beneath it. */
  readonly name: string
  /** PNG data URL, for a drawn signature only. */
  readonly image?: string | null
}

/** Roughly 1MB of base64 — a generous signature, a refused screenshot. */
const MAX_IMAGE_CHARS = 1_400_000
const PNG_DATA_URL = /^data:image\/png;base64,[A-Za-z0-9+/]+=*$/

export function signatureProblem(input: SignatureInput): string | null {
  const name = input.name.trim()
  if (name.length < 2) return 'Type your full name as your signature.'
  if (name.length > 120) return 'That name is too long.'

  if (input.method === 'typed') return null

  const image = (input.image ?? '').trim()
  if (!image) return 'Draw your signature, or switch to typing it.'
  if (!PNG_DATA_URL.test(image)) return 'That signature could not be read. Draw it again.'
  if (image.length > MAX_IMAGE_CHARS) return 'That signature is too large. Draw it again.'
  return null
}

/**
 * What each side is putting their name to.
 *
 * Written out rather than implied, because "I signed the form" is worth nothing
 * in an argument and "I confirm I have handed back the equipment listed" is
 * worth something. Both carry the capacity — signing for yourself is a
 * different act from signing for a company.
 */
export type ReturnStatements = {
  readonly person: string
  readonly hr: string
}

export function returnStatements(companyName: string): ReturnStatements {
  return {
    person:
      'I confirm that I have handed back the equipment listed on this form, ' +
      'in the condition recorded, and that I keep nothing further belonging to the company.',
    hr:
      `I confirm that I have received the equipment listed on this form on behalf of ${companyName}, ` +
      'and that I am authorised to accept it.',
  }
}

export function capacityFor(role: 'person' | 'hr', companyName: string): string {
  return role === 'person' ? 'The person returning the equipment' : `For ${companyName}`
}
