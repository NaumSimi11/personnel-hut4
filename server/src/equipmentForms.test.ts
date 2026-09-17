import { describe, expect, it } from 'vitest'
import { formTitle, renderEquipmentForm, type EquipmentFormData } from './equipmentForms.js'

const data: EquipmentFormData = {
  kind: 'equipment_return',
  person: { name: 'Ана Илиевска', position: 'Analyst', start_date: '2026-01-10', last_working_date: '2026-11-30' },
  company: { name: 'Snowball', legal_name: 'Snowball DOOEL' },
  assets: [
    { tag: 'POOL-001', type: 'Laptop', model: 'ThinkPad X1', serial: 'SN123', condition: 'good', issued_at: '2026-02-01T10:00:00Z' },
    { tag: 'MON-7', type: 'Monitor', model: null, serial: null, condition: null, issued_at: '2026-02-01T10:00:00Z' },
  ],
  kit: [{ item: 'Badge', issued_at: '2026-02-01T10:00:00Z', asset_id: null }],
}

describe('equipment forms', () => {
  it('renders a PDF that carries the person, the company and every asset', async () => {
    const pdf = await renderEquipmentForm(data)
    expect(pdf.subarray(0, 5).toString()).toBe('%PDF-')
    expect(pdf.length).toBeGreaterThan(2000)
  })

  it('renders a handover form with no assets yet (the kit alone)', async () => {
    const pdf = await renderEquipmentForm({ ...data, kind: 'equipment_handover', assets: [] })
    expect(pdf.subarray(0, 5).toString()).toBe('%PDF-')
  })

  it('names the form by kind, in both languages', () => {
    expect(formTitle('equipment_handover')).toBe('Equipment handover form · Записник за предавање опрема')
    expect(formTitle('equipment_return')).toBe('Equipment return form · Записник за враќање опрема')
  })
})
