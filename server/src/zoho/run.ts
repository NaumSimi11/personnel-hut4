import { serviceDb } from '../supabaseAdmin.js'
import { createZohoClient } from './client.js'
import { syncZohoProjects } from './sync.js'

/**
 * CLI entry point: `npm run sync:zoho [-- --dry-run]`. Prints a human
 * summary only — never a token, header, or raw error body.
 */
async function main() {
  const dryRun = process.argv.includes('--dry-run')

  const client = await createZohoClient()
  const result = await syncZohoProjects({ client, db: serviceDb(), dryRun })

  const prefix = dryRun ? '[zoho-sync] [dry run]' : '[zoho-sync]'
  console.log(`${prefix} companies configured: ${result.companies}`)
  console.log(
    `${prefix} projects seen: ${result.projectsSeen}, synced: ${result.projectsSynced}, members synced: ${result.membersSynced}`,
  )
  if (result.unmatchedProjects.length > 0) {
    const sample = result.unmatchedProjects.slice(0, 5).map((project) => project.name)
    console.log(`${prefix} ${result.unmatchedProjects.length} unmatched project(s), e.g.: ${sample.join(', ')}`)
  }
  if (result.unmatchedMemberEmails.length > 0) {
    console.log(`${prefix} ${result.unmatchedMemberEmails.length} unmatched member email(s)`)
  }
}

main().catch((error) => {
  console.error(`[zoho-sync] failed: ${error instanceof Error ? error.message : 'Unknown error'}`)
  process.exit(1)
})
