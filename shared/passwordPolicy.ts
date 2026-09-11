/**
 * The password policy, defined once. Ported from the Hut4 leave system.
 *
 * The server enforces these rules in the change-password endpoint; the
 * first-sign-in form renders them as a live checklist. One list, two
 * consumers — the checkmarks a person watches and the validation that can
 * reject them are the same code, so they cannot drift apart.
 */
export type PasswordRule = {
  id: 'length' | 'cases' | 'number'
  label: string
  test: (password: string) => boolean
}

export const PASSWORD_RULES: readonly PasswordRule[] = [
  {
    id: 'length',
    label: 'At least 12 characters',
    test: (password) => password.length >= 12,
  },
  {
    id: 'cases',
    label: 'Upper and lower case letters',
    test: (password) => /[a-z]/.test(password) && /[A-Z]/.test(password),
  },
  {
    id: 'number',
    label: 'At least one number',
    test: (password) => /[0-9]/.test(password),
  },
]

export function meetsPasswordPolicy(password: string): boolean {
  return PASSWORD_RULES.every((rule) => rule.test(password))
}

/** One sentence for error messages, built from the rules themselves. */
export const PASSWORD_POLICY_SUMMARY =
  'The password needs at least 12 characters, upper and lower case letters, and a number.'
