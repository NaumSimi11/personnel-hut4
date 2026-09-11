import { readFileSync } from 'node:fs'
import { fileURLToPath, URL } from 'node:url'

/**
 * Environment for the auth service. Values come from the repo-root .env.local
 * (gitignored) with process.env taking precedence, so deployment platforms can
 * inject real env vars without the file.
 */
function parseEnvFile(): Record<string, string> {
  try {
    const raw = readFileSync(fileURLToPath(new URL('../../.env.local', import.meta.url)), 'utf8')
    return Object.fromEntries(
      raw
        .split('\n')
        .filter((line) => /^[A-Z0-9_]+=/.test(line))
        .map((line) => {
          const idx = line.indexOf('=')
          return [line.slice(0, idx), line.slice(idx + 1)] as const
        }),
    )
  } catch {
    return {}
  }
}

const fileEnv = parseEnvFile()

export function env(name: string): string | undefined {
  return process.env[name]?.trim() || fileEnv[name]?.trim() || undefined
}

export function requiredEnv(name: string): string {
  const value = env(name)
  if (!value) throw new Error(`${name} is not configured`)
  return value
}
