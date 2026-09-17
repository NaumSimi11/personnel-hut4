import { renderPdf } from './pdf.js'

/**
 * A contract, as a page somebody can print and sign.
 *
 * Deliberately plain: a title, the parties, the body as written, and signature
 * blocks with room for a pen. The body arrives already filled in — this module
 * decides nothing about content, only how it sits on paper, so a change to the
 * wording is a change to the template and never a deployment.
 */
export type ContractPdfData = {
  readonly title: string
  readonly companyName: string
  readonly personName: string
  readonly body: string
  readonly issuedOn: string
  readonly version: number
}

/** Blank lines separate paragraphs; a single newline is a line break within one. */
function paragraphs(body: string): { text: string; margin: [number, number, number, number] }[] {
  return body
    .split(/\n\s*\n/)
    .map((block) => block.trim())
    .filter((block) => block !== '')
    .map((block) => ({ text: block, margin: [0, 0, 0, 10] as [number, number, number, number] }))
}

export async function renderContract(data: ContractPdfData): Promise<Buffer> {
  return renderPdf({
    pageSize: 'A4',
    pageMargins: [56, 60, 56, 70],
    defaultStyle: { fontSize: 10, lineHeight: 1.35 },
    content: [
      { text: data.companyName, fontSize: 9, color: '#6b7280', margin: [0, 0, 0, 4] },
      { text: data.title, fontSize: 16, bold: true, margin: [0, 0, 0, 16] },
      ...paragraphs(data.body),
      { text: '', margin: [0, 18, 0, 0] },
      {
        columns: [
          {
            width: '*',
            stack: [
              { text: '\n\n', fontSize: 10 },
              { canvas: [{ type: 'line', x1: 0, y1: 0, x2: 190, y2: 0, lineWidth: 0.8 }] },
              { text: data.personName, fontSize: 9, margin: [0, 5, 0, 0] },
              { text: 'Signature and date', fontSize: 8, color: '#6b7280' },
            ],
          },
          { width: 40, text: '' },
          {
            width: '*',
            stack: [
              { text: '\n\n', fontSize: 10 },
              { canvas: [{ type: 'line', x1: 0, y1: 0, x2: 190, y2: 0, lineWidth: 0.8 }] },
              { text: `For ${data.companyName}`, fontSize: 9, margin: [0, 5, 0, 0] },
              { text: 'Signature and date', fontSize: 8, color: '#6b7280' },
            ],
          },
        ],
      },
    ],
    footer: (page: number, pages: number) => ({
      columns: [
        { text: `${data.title} · template v${data.version} · issued ${data.issuedOn}`, fontSize: 7, color: '#9ca3af' },
        { text: `${page} / ${pages}`, fontSize: 7, color: '#9ca3af', alignment: 'right' },
      ],
      margin: [56, 18, 56, 0],
    }),
  })
}
