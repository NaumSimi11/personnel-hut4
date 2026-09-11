import { ref } from 'vue'
import { defineStore } from 'pinia'
import { supabase } from '@/lib/supabase'
import type { Capability, DependencyMap } from '@/lib/permissions'

export type Preset = { id: string; name: string; capabilities: string[] }
export type CapabilityGroup = { name: string; capabilities: Capability[] }

// Presentation order for the seeded groups (the catalog itself is data; only
// the display order is a UI decision). Unknown groups append at the end.
const GROUP_ORDER = [
  'Employee records',
  'Compensation & payroll',
  'Recruitment',
  'Documents & onboarding',
  'Equipment & IT',
  'Recruitment marketing',
  'Projects & work',
  'Administration',
]

export const useAccessCatalog = defineStore('accessCatalog', () => {
  const groups = ref<CapabilityGroup[]>([])
  const labels = ref<Record<string, string>>({})
  const dependencies = ref<DependencyMap>({})
  const presets = ref<Preset[]>([])
  const loaded = ref(false)
  const error = ref<string | null>(null)

  async function load(): Promise<void> {
    if (loaded.value) return
    const [caps, deps, presetRows] = await Promise.all([
      supabase
        .from('capabilities')
        .select('key, group_name, label, sensitive, sort_order')
        .is('archived_at', null)
        .order('sort_order'),
      supabase.from('capability_dependencies').select('capability_key, requires_key'),
      supabase
        .from('permission_presets')
        .select('id, name, preset_capabilities(capability_key)')
        .is('archived_at', null)
        .order('name'),
    ])
    const failure = caps.error ?? deps.error ?? presetRows.error
    if (failure) {
      error.value = 'Could not load the permission catalog.'
      console.error('Access catalog load failed:', failure.message)
      return
    }

    const byGroup = new Map<string, Capability[]>()
    for (const cap of caps.data ?? []) {
      const list = byGroup.get(cap.group_name) ?? []
      byGroup.set(cap.group_name, [...list, cap])
      labels.value = { ...labels.value, [cap.key]: cap.label }
    }
    const orderedNames = [
      ...GROUP_ORDER.filter((name) => byGroup.has(name)),
      ...[...byGroup.keys()].filter((name) => !GROUP_ORDER.includes(name)),
    ]
    groups.value = orderedNames.map((name) => ({ name, capabilities: byGroup.get(name) ?? [] }))

    dependencies.value = (deps.data ?? []).reduce<DependencyMap>(
      (map, row) => ({
        ...map,
        [row.capability_key]: [...(map[row.capability_key] ?? []), row.requires_key],
      }),
      {},
    )

    presets.value = (presetRows.data ?? []).map((p) => ({
      id: p.id,
      name: p.name,
      capabilities: (p.preset_capabilities ?? []).map((c) => c.capability_key),
    }))
    loaded.value = true
  }

  return { groups, labels, dependencies, presets, loaded, error, load }
})
