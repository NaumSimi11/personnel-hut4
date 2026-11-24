import { describe, expect, it, vi } from 'vitest'

vi.mock('./supabase.js', () => ({ serviceDb: () => ({ rpc: async () => ({ error: null }) }) }))
const { runEquipmentCheckClocks } = await import('./equipmentClocks.js')

describe('equipment check clocks (0130)', () => {
  it('runs the database clock once', async () => {
    const rpc = vi.fn(async () => ({ error: null }))
    await runEquipmentCheckClocks({ rpc })
    expect(rpc).toHaveBeenCalledWith('run_equipment_check_clocks')
  })

  it('logs a failure instead of stopping the delivery', async () => {
    const spy = vi.spyOn(console, 'error').mockImplementation(() => {})
    await expect(runEquipmentCheckClocks({ rpc: async () => ({ error: { message: 'boom' } }) })).resolves.toBeUndefined()
    expect(spy).toHaveBeenCalledWith('[equipment-check-clocks] failed:', 'boom')
    spy.mockRestore()
  })
})
