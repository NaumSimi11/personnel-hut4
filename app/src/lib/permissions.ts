// Pure capability-set logic, mirroring the rules the database seeds in
// capability_dependencies: enabling an action also enables what it requires;
// removing a prerequisite cascades away everything that depended on it.

export type Capability = {
  key: string
  group_name: string
  label: string
  sensitive: boolean
  sort_order: number
}

/** capability key -> keys it requires */
export type DependencyMap = Record<string, readonly string[]>

export function withDependencies(
  selected: ReadonlySet<string>,
  key: string,
  deps: DependencyMap,
): Set<string> {
  const next = new Set(selected)
  const add = (k: string): void => {
    if (next.has(k)) return
    next.add(k)
    for (const required of deps[k] ?? []) add(required)
  }
  add(key)
  return next
}

export function withoutDependents(
  selected: ReadonlySet<string>,
  key: string,
  deps: DependencyMap,
): Set<string> {
  const next = new Set(selected)
  next.delete(key)
  let changed = true
  while (changed) {
    changed = false
    for (const k of [...next]) {
      if ((deps[k] ?? []).some((required) => !next.has(required))) {
        next.delete(k)
        changed = true
      }
    }
  }
  return next
}

export function diffSets(
  before: ReadonlySet<string>,
  after: ReadonlySet<string>,
): { added: string[]; removed: string[] } {
  return {
    added: [...after].filter((k) => !before.has(k)),
    removed: [...before].filter((k) => !after.has(k)),
  }
}
