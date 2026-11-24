/**
 * The buddy on an onboarding checklist (audit C3, migration 0128): a current
 * colleague picked from the company's employees. The database checks who may
 * pick, who may be picked, ticks "Buddy assigned" and tells the buddy.
 */
export type BuddyOption = { id: string; full_name: string; job_title: string | null }

export function buddyLine(name: string | null): string {
  return name ? `Buddy: ${name}. They were told in PeopleOS.` : 'No buddy picked yet.'
}

export function buddyOptionLabel(o: BuddyOption): string {
  return o.job_title ? `${o.full_name} · ${o.job_title}` : o.full_name
}
