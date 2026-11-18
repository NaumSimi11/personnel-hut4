import type { PublicCompany } from '@/components/CareersFrame.vue'

/**
 * The public careers endpoints (plan 019). No Supabase client, no session:
 * plain fetches to the auth service, which is the only thing an anonymous
 * visitor may talk to.
 */

export type PublicJobSummary = { id: string; title: string; summary: string }

export type PublicQuestion = {
  id: string
  prompt: string
  kind: 'text' | 'yes_no' | 'choice'
  required: boolean
  options?: string[]
}

export type PublicBrief = { id: string; title: string; description: string; questions: PublicQuestion[] }

async function readJson<T>(response: Response): Promise<T> {
  const body = (await response.json().catch(() => ({}))) as T & { error?: string }
  if (!response.ok) throw new Error(body.error ?? 'Something went wrong. Please try again.')
  return body
}

export async function fetchCareersCompany(code: string): Promise<{ company: PublicCompany; jobs: PublicJobSummary[] }> {
  return readJson(await fetch(`/api/careers/${encodeURIComponent(code)}`))
}

/** HR's privacy notice for the form (board card C4, 0118); null when none is written. */
export type PrivacyNotice = { title: string; paragraphs: string[] }

export async function fetchCareersJob(
  code: string,
  jobId: string,
): Promise<{ company: PublicCompany; job: PublicBrief; privacy?: PrivacyNotice | null }> {
  return readJson(await fetch(`/api/careers/${encodeURIComponent(code)}/jobs/${encodeURIComponent(jobId)}`))
}

export async function submitApplication(code: string, jobId: string, form: FormData): Promise<{ reference: string }> {
  return readJson(
    await fetch(`/api/careers/${encodeURIComponent(code)}/jobs/${encodeURIComponent(jobId)}/applications`, {
      method: 'POST',
      body: form,
    }),
  )
}
