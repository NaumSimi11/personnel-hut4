import { randomBytes } from 'node:crypto'

/**
 * Pure account/identity logic — ported from the Hut4 leave system's
 * authAccount.ts. No I/O here; every rule is unit-testable.
 */

/** Comma-separated env value -> normalised domain list. */
export function parseAllowedDomains(raw: string | undefined): string[] {
  if (!raw) return []
  const seen = new Set<string>()
  for (const domain of raw.split(',')) {
    const normalized = domain.trim().toLowerCase()
    if (normalized) seen.add(normalized)
  }
  return [...seen]
}

/**
 * Invite-door policy: the address must be exactly on one of the company
 * domains. Subdomains and lookalikes are rejected; an empty allowlist admits
 * nobody (fail closed).
 */
export function isAllowedEmail(email: string, domains: string[]): boolean {
  const match = /^[^\s@]+@([^\s@]+)$/.exec(email.trim().toLowerCase())
  if (!match) return false
  return domains.includes(match[1])
}

/**
 * First password for an invited account. Alphanumeric only, so it survives
 * copy-paste, chat clients, and being read out loud. ~119 bits of entropy;
 * it must be changed on first login regardless.
 */
export function generateTempPassword(): string {
  const alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789'
  const bytes = randomBytes(20)
  let out = ''
  for (let i = 0; i < bytes.length; i++) out += alphabet[bytes[i] % alphabet.length]
  return out
}
