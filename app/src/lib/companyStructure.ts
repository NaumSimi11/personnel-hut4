import { supabase } from '@/lib/supabase'

/**
 * The company's structure — departments and locations a period may point
 * at: the company's own plus the holding-wide ones (no company). One
 * loader and one adder for every dialog that offers them (plan 046),
 * so the scope rule lives in one place.
 */

export type StructureOption = { id: string; name: string }
export type Structure = { departments: StructureOption[]; locations: StructureOption[] }

export const EMPTY_STRUCTURE: Structure = { departments: [], locations: [] }

/** Rejects with a readable message when either query fails. */
export async function loadCompanyStructure(companyId: string): Promise<Structure> {
  if (!companyId) return EMPTY_STRUCTURE
  const scope = `company_id.eq.${companyId},company_id.is.null`
  const [deptRes, locRes] = await Promise.all([
    supabase.from('departments').select('id, name').or(scope).is('archived_at', null).order('name'),
    supabase.from('locations').select('id, name').or(scope).is('archived_at', null).order('name'),
  ])
  const failed = deptRes.error ?? locRes.error
  if (failed) {
    console.error('Structure load failed:', failed.message)
    throw new Error('Could not load departments and locations.')
  }
  return { departments: deptRes.data ?? [], locations: locRes.data ?? [] }
}

/** Adds a department to the company and returns it; HR (employment.edit) may since 0038. */
export async function addDepartment(companyId: string, name: string): Promise<StructureOption> {
  const trimmed = name.trim()
  if (trimmed.length < 2) throw new Error('Enter the department name.')
  const { data, error } = await supabase
    .from('departments')
    .insert({ company_id: companyId, name: trimmed })
    .select('id, name')
    .single()
  if (error || !data) throw new Error(friendlyStructureError(error?.message ?? 'row-level security'))
  return data
}

export function friendlyStructureError(message: string): string {
  if (/row-level security/.test(message)) return 'Changing the structure needs employment.edit in this company.'
  if (/unique|duplicate/i.test(message)) return 'That name already exists here.'
  return message
}

/** A new option in its sorted place, without touching the given list. */
export function withOption(list: StructureOption[], option: StructureOption): StructureOption[] {
  return [...list, option].sort((a, b) => a.name.localeCompare(b.name))
}
