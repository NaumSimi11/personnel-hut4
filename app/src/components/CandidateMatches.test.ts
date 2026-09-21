import { describe, expect, it } from 'vitest'
import { createSSRApp, defineComponent, h } from 'vue'
import { renderToString } from 'vue/server-renderer'
import CandidateMatches from '@/components/CandidateMatches.vue'
import type { CandidateMatch } from '@/lib/candidatePool'

// Rendered through the server renderer: the repo has no DOM harness, and what
// matters here is the markup — a busy dialog must not offer a second click on
// "Attach to this job" or "Create a new candidate anyway" (a double-click would
// otherwise insert the duplicate the hint exists to prevent).

const match: CandidateMatch = {
  id: 'c1',
  full_name: 'Ana Petrova',
  match: 'email',
  visible: false,
  attachable: true,
  do_not_contact: false,
  contact_later: false,
  contact_again_after: null,
  email: 'ana@example.com',
  phone: null,
  linkedin_url: null,
  current_title: null,
  current_employer: null,
  last_activity_at: null,
  applications: [],
}

// The template resolves `router-link` even when nothing renders it; a stub
// keeps the run free of Vue warnings without mounting the real router.
const RouterLinkStub = defineComponent({
  props: { to: { type: Object, required: true } },
  setup(props, { slots }) {
    return () => h('a', { 'data-to': JSON.stringify(props.to) }, slots.default?.())
  },
})

function render(props: { matches: CandidateMatch[]; mode: 'job' | 'pool'; busy?: boolean }): Promise<string> {
  const app = createSSRApp(CandidateMatches, props)
  app.component('router-link', RouterLinkStub)
  return renderToString(app)
}

function button(html: string, testid: string): string {
  const m = html.match(new RegExp(`<button[^>]*data-testid="${testid}"[^>]*>`))
  if (!m) throw new Error(`no button ${testid} in ${html}`)
  return m[0]
}

describe('CandidateMatches', () => {
  it('offers attach, back and create-new when idle', async () => {
    const html = await render({ matches: [match], mode: 'job' })
    expect(html).toContain('Is this the same person?')
    expect(html).toContain('This looks like Ana Petrova (same email).')
    expect(button(html, 'match-attach-c1')).not.toContain('disabled')
    expect(button(html, 'match-create-new')).not.toContain('disabled')
    expect(button(html, 'match-back')).not.toContain('disabled')
  })

  it('disables every button while the dialog is busy', async () => {
    const html = await render({ matches: [match], mode: 'job', busy: true })
    expect(button(html, 'match-attach-c1')).toContain('disabled')
    expect(button(html, 'match-create-new')).toContain('disabled')
    expect(button(html, 'match-back')).toContain('disabled')
  })

  it('links to the record only when the match is visible', async () => {
    const hidden = await render({ matches: [match], mode: 'job' })
    expect(hidden).not.toContain('Open')
    const shown = await render({ matches: [{ ...match, visible: true }], mode: 'job' })
    expect(shown).toContain('&quot;name&quot;:&quot;candidate&quot;')
    expect(shown).toContain('&quot;candidateId&quot;:&quot;c1&quot;')
  })

  it('has nothing to attach to in pool mode', async () => {
    const html = await render({ matches: [match], mode: 'pool' })
    expect(html).not.toContain('match-attach-c1')
    expect(button(html, 'match-create-new')).not.toContain('disabled')
  })
})
