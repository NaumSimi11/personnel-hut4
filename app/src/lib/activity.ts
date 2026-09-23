/**
 * Activity history (plan 030): turns audit rows (activity_log, migration
 * 0005; redacted by 0018/0020) into something a person can read — which
 * entity, what happened, and which fields changed.
 */

export const ENTITY_LABELS: Record<string, string> = {
  employment_periods: 'Employment',
  employment_changes: 'Employment change',
  access_grants: 'Access grant',
  grant_capabilities: 'Capability',
  platform_admins: 'Platform admin',
  hiring_requests: 'Hiring request',
  jobs: 'Job',
  job_channels: 'Job channel',
  promotions: 'Promotion',
  applications: 'Application',
  application_files: 'Candidate file',
  interviews: 'Interview',
  scorecards: 'Scorecard',
  offers: 'Offer',
  compensation_records: 'Compensation',
  documents: 'Document',
  integrations: 'Integration',
  workflow_owners: 'Workflow owner',
  payroll_periods: 'Payroll period',
  assets: 'Asset',
  asset_assignments: 'Asset assignment',
  it_requests: 'IT request',
}

export function entityLabel(type: string): string {
  return ENTITY_LABELS[type] ?? type.replace(/_/g, ' ')
}

const ACTION_LABELS: Record<string, string> = { INSERT: 'created', UPDATE: 'updated', DELETE: 'removed' }

export function actionLabel(action: string): string {
  return ACTION_LABELS[action] ?? action.toLowerCase()
}

// Bookkeeping columns say nothing about what a person did.
const SKIP = new Set(['id', 'created_at', 'updated_at', 'company_id', 'created_by', 'uploaded_by', 'actor_id'])
// On an insert these are what identify the row to a reader.
const NOTABLE = ['title', 'job_title', 'full_name', 'asset_tag', 'name', 'capability_key', 'category_key', 'status', 'stage_key', 'kind', 'amount', 'effective_date', 'start_date', 'visibility', 'version']
const MAX_ITEMS = 4
const MAX_VALUE = 40

type Row = Record<string, unknown>

function fieldLabel(key: string): string {
  const words = key.replace(/_id$/, '').replace(/_/g, ' ')
  return words.charAt(0).toUpperCase() + words.slice(1)
}

function show(value: unknown): string {
  if (value === null || value === undefined || value === '') return '—'
  if (typeof value === 'object') return 'changed'
  const text = String(value)
  return text.length > MAX_VALUE ? `${text.slice(0, MAX_VALUE - 1)}…` : text
}

function cap(items: string[]): string[] {
  if (items.length <= MAX_ITEMS) return items
  return [...items.slice(0, MAX_ITEMS), `… and ${items.length - MAX_ITEMS} more`]
}

export function summarizeChange(action: string, before: Row | null, after: Row | null): string[] {
  if (action === 'UPDATE' && before && after) {
    const keys = [...new Set([...Object.keys(before), ...Object.keys(after)])].filter((k) => !SKIP.has(k))
    const changed = keys.filter((k) => JSON.stringify(before[k]) !== JSON.stringify(after[k]))
    return cap(
      changed.map((k) =>
        typeof after[k] === 'object' && after[k] !== null
          ? `${fieldLabel(k)}: changed`
          : `${fieldLabel(k)}: ${show(before[k])} → ${show(after[k])}`,
      ),
    )
  }
  const row = action === 'DELETE' ? before : after
  if (!row) return []
  const present = NOTABLE.filter((k) => k in row && row[k] !== null && row[k] !== '' && typeof row[k] !== 'object')
  const picked = action === 'DELETE' ? present.slice(0, 1) : present
  return cap(picked.map((k) => `${fieldLabel(k)}: ${show(row[k])}`))
}

// ------------------------------------------------------------- filtering
/**
 * Reading the trail (plan 059).
 *
 * The panel used to load the most recent 200 rows and filter those in the
 * page. After the Zoho import wrote some 24,000 rows in one burst, the most
 * recent 200 are all import — so filtering by entity, or searching a
 * colleague's name, searched inside the import and found nothing. Ivana's 55
 * real changes were invisible behind Naum's 12,902 imported ones.
 *
 * So the filters below are applied by the *query*, not to what it returned.
 * These are the pieces both the panel and its tests agree on.
 */

export type ActivityPeriod = '7' | '30' | '90' | 'all'

export const PERIOD_LABELS: Record<ActivityPeriod, string> = {
  '7': 'Last 7 days',
  '30': 'Last 30 days',
  '90': 'Last 90 days',
  all: 'All time',
}

/** The default: recent enough to be today's work, wide enough to hold a week off. */
export const DEFAULT_PERIOD: ActivityPeriod = '30'

/**
 * The instant a period starts, or null for all time. Returned as an ISO
 * string because that is what the query wants, and computed from UTC
 * midnight so a filter does not shift with the hour it is used at.
 */
export function periodStart(period: ActivityPeriod, now = new Date()): string | null {
  if (period === 'all') return null
  const start = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()))
  start.setUTCDate(start.getUTCDate() - Number(period))
  return start.toISOString()
}

export type ActorChoice = { id: string; full_name: string }

/** "Anyone" and "The system itself" are not people, so they are not ids. */
export const ANY_ACTOR = ''
export const SYSTEM_ACTOR = 'system'

/** What the heading says about what is on screen. */
export function activityCount(shown: number, limit: number): string {
  if (shown < limit) return `${shown} ${shown === 1 ? 'change' : 'changes'}`
  return `the ${limit} most recent changes`
}
