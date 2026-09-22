import { describe, expect, it } from 'vitest'
import { MAX_PAGES, PAGE_SIZE, pageAll, type PageResult } from './pageAll'

type Row = { id: number }

/** A fake query over `total` rows that records the windows it was asked for. */
function fakeSource(total: number, pageSize = PAGE_SIZE) {
  const all: Row[] = Array.from({ length: total }, (_, i) => ({ id: i }))
  const windows: Array<[number, number]> = []
  const fetchPage = async (from: number, to: number): Promise<PageResult<Row>> => {
    windows.push([from, to])
    return { data: all.slice(from, Math.min(to + 1, from + pageSize)), error: null }
  }
  return { fetchPage, windows }
}

describe('pageAll', () => {
  it('stops after one window when the first page is short', async () => {
    const { fetchPage, windows } = fakeSource(3, 10)
    const { data, error } = await pageAll(fetchPage, { pageSize: 10 })
    expect(error).toBeNull()
    expect(data.map((r) => r.id)).toEqual([0, 1, 2])
    expect(windows).toEqual([[0, 9]])
  })

  it('walks full windows and returns every row once, in order', async () => {
    const { fetchPage, windows } = fakeSource(25, 10)
    const { data } = await pageAll(fetchPage, { pageSize: 10 })
    expect(data).toHaveLength(25)
    expect(data.map((r) => r.id)).toEqual(Array.from({ length: 25 }, (_, i) => i))
    expect(windows).toEqual([
      [0, 9],
      [10, 19],
      [20, 29],
    ])
  })

  it('asks for one more window when the last full page lands exactly on the end', async () => {
    const { fetchPage, windows } = fakeSource(20, 10)
    const { data } = await pageAll(fetchPage, { pageSize: 10 })
    expect(data).toHaveLength(20)
    expect(windows).toHaveLength(3)
  })

  it('never asks for more than maxPages windows', async () => {
    const { fetchPage, windows } = fakeSource(1000, 10)
    const { data } = await pageAll(fetchPage, { pageSize: 10, maxPages: 3 })
    expect(data).toHaveLength(30)
    expect(windows).toHaveLength(3)
  })

  it('defaults to five windows of a thousand rows', async () => {
    const { fetchPage, windows } = fakeSource(6000)
    const { data } = await pageAll(fetchPage)
    expect(windows).toHaveLength(MAX_PAGES)
    expect(windows[0]).toEqual([0, PAGE_SIZE - 1])
    expect(data).toHaveLength(MAX_PAGES * PAGE_SIZE)
  })

  it('aborts with no rows on the first error', async () => {
    let calls = 0
    const fetchPage = async (): Promise<PageResult<Row>> => {
      calls += 1
      if (calls === 2) return { data: null, error: { message: 'boom' } }
      return { data: Array.from({ length: 10 }, (_, i) => ({ id: i })), error: null }
    }
    const { data, error } = await pageAll(fetchPage, { pageSize: 10 })
    expect(error).toEqual({ message: 'boom' })
    expect(data).toEqual([])
    expect(calls).toBe(2)
  })

  it('treats a null page as empty and stops', async () => {
    const fetchPage = async (): Promise<PageResult<Row>> => ({ data: null, error: null })
    const { data, error } = await pageAll(fetchPage, { pageSize: 10 })
    expect(error).toBeNull()
    expect(data).toEqual([])
  })
})
