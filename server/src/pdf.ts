// Static imports so esbuild inlines pdfmake and the font into the Vercel bundle.
import pdfmakeInstance from 'pdfmake'
import roboto from 'pdfmake/build/fonts/Roboto.js'

/**
 * One pdfmake engine for every generated document (plans 049, 050): the
 * bundled Roboto (Latin + Cyrillic) in the virtual file system, no local
 * or remote file access, set up once per process.
 */
type PdfMake = {
  virtualfs: { writeFileSync: (name: string, content: string, encoding: string) => void }
  addFonts: (fonts: Record<string, Record<string, string>>) => void
  setLocalAccessPolicy: (cb: (path: string) => boolean) => void
  setUrlAccessPolicy: (cb: (url: string) => boolean) => void
  createPdf: (doc: Record<string, unknown>) => { getBuffer: () => Promise<Uint8Array> }
}

let engine: PdfMake | null = null

/** pdfmake with the bundled Roboto (Latin + Cyrillic) in its virtual file system; set up once. */
function pdfmake(): PdfMake {
  if (engine) return engine
  const instance = pdfmakeInstance as unknown as PdfMake
  const font = roboto as unknown as { vfs: Record<string, { data: string } | string>; fonts: Record<string, Record<string, string>> }
  for (const [name, entry] of Object.entries(font.vfs)) {
    instance.virtualfs.writeFileSync(name, typeof entry === 'string' ? entry : entry.data, 'base64')
  }
  instance.addFonts(font.fonts)
  instance.setLocalAccessPolicy(() => false)
  instance.setUrlAccessPolicy(() => false)
  engine = instance
  return engine
}


export async function renderPdf(doc: Record<string, unknown>): Promise<Buffer> {
  const bytes = await pdfmake().createPdf(doc).getBuffer()
  return Buffer.from(bytes)
}
