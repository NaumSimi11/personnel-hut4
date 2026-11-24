import { serviceDb } from './supabaseAdmin.js'

/** The yearly equipment check's reminders and overdue notice (0130); their notices land in the queue. */
export async function runEquipmentCheckClocks(db: { rpc(name: string): PromiseLike<{ error: { message: string } | null }> } = serviceDb()): Promise<void> {
  const { error } = await db.rpc('run_equipment_check_clocks')
  if (error) console.error('[equipment-check-clocks] failed:', error.message)
}
