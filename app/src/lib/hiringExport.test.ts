import { describe, expect, it, vi } from 'vitest'
import { HIRING_EXPORT_ERROR, fetchHiringExport } from './hiringExport'

function answer(status: number, body: unknown): typeof fetch {
  return vi.fn(async () => new Response(JSON.stringify(body), { status })) as unknown as typeof fetch
}

describe('fetchHiringExport', () => {
  it('posts the day with the caller token and decodes the file', async () => {
    const fetcher = answer(200, { filename: 'peopleos-candidates-2026-11-17.xlsx', base64: btoa('PK') })
    const file = await fetchHiringExport('tok', '2026-11-17', fetcher)
    expect(file.filename).toBe('peopleos-candidates-2026-11-17.xlsx')
    expect(Array.from(file.bytes)).toEqual([80, 75])
    const [url, init] = (fetcher as unknown as ReturnType<typeof vi.fn>).mock.calls[0]
    expect(url).toBe('/api/reports/hiring-export')
    expect(init.headers.authorization).toBe('Bearer tok')
    expect(JSON.parse(init.body)).toEqual({ today: '2026-11-17' })
  })

  it('throws the server message when it refuses', async () => {
    await expect(fetchHiringExport('tok', '2026-11-17', answer(401, { error: 'Sign in to continue.' }))).rejects.toThrow('Sign in to continue.')
  })

  it('throws a plain message when the answer is not a file', async () => {
    await expect(fetchHiringExport('tok', '2026-11-17', answer(200, {}))).rejects.toThrow(HIRING_EXPORT_ERROR)
    await expect(fetchHiringExport('tok', '2026-11-17', answer(500, 'oops'))).rejects.toThrow(HIRING_EXPORT_ERROR)
  })
})
