import { deflateRawSync } from 'node:zlib'

/**
 * A ZIP container, by hand.
 *
 * An .xlsx *is* a zip of XML parts, and the repo carries no spreadsheet
 * library — it only hand-reads worksheet XML for the equipment import
 * (`popisXlsxCells.ts`). Writing one needs about a hundred lines: the deflate
 * is Node's own, so all this adds is the framing.
 *
 * Only what a workbook needs is implemented: no encryption, no zip64, no
 * directory entries, no comments. A workbook that large is not a report.
 */

/** CRC-32 (IEEE 802.3), the checksum every zip entry carries. */
const CRC_TABLE = (() => {
  const table = new Uint32Array(256)
  for (let n = 0; n < 256; n += 1) {
    let c = n
    for (let k = 0; k < 8; k += 1) c = c & 1 ? 0xedb88320 ^ (c >>> 1) : c >>> 1
    table[n] = c >>> 0
  }
  return table
})()

export function crc32(data: Uint8Array): number {
  let c = 0xffffffff
  for (let i = 0; i < data.length; i += 1) c = CRC_TABLE[(c ^ data[i]) & 0xff] ^ (c >>> 8)
  return (c ^ 0xffffffff) >>> 0
}

export type ZipEntry = { name: string; data: Buffer }

/**
 * MS-DOS date and time, which is what a zip header stores.
 *
 * Seconds have one bit less than they need, so they count in twos; years
 * start at 1980. A date before that cannot be written at all, so the epoch
 * is the floor — a report's entries are stamped "now" anyway.
 */
export function dosStamp(at: Date): { time: number; date: number } {
  const year = Math.max(1980, at.getFullYear())
  return {
    time: (at.getHours() << 11) | (at.getMinutes() << 5) | (at.getSeconds() >> 1),
    date: ((year - 1980) << 9) | ((at.getMonth() + 1) << 5) | at.getDate(),
  }
}

/** One entry's local header, followed by its deflated bytes. */
function localPart(entry: ZipEntry, stamp: { time: number; date: number }) {
  const name = Buffer.from(entry.name, 'utf8')
  const compressed = deflateRawSync(entry.data)
  const header = Buffer.alloc(30)
  header.writeUInt32LE(0x04034b50, 0) // local file header
  header.writeUInt16LE(20, 4) // version needed: 2.0, deflate
  header.writeUInt16LE(0, 6) // no flags — sizes are known before writing
  header.writeUInt16LE(8, 8) // deflate
  header.writeUInt16LE(stamp.time, 10)
  header.writeUInt16LE(stamp.date, 12)
  header.writeUInt32LE(crc32(entry.data), 14)
  header.writeUInt32LE(compressed.length, 18)
  header.writeUInt32LE(entry.data.length, 22)
  header.writeUInt16LE(name.length, 26)
  header.writeUInt16LE(0, 28) // no extra field
  return { name, compressed, header, crc: crc32(entry.data) }
}

/**
 * Pack entries into a zip archive.
 *
 * `at` stamps every entry; passing a fixed date makes the output
 * byte-for-byte reproducible, which is what the tests rely on.
 */
export function zip(entries: ReadonlyArray<ZipEntry>, at: Date = new Date()): Buffer {
  const stamp = dosStamp(at)
  const parts: Buffer[] = []
  const central: Buffer[] = []
  let offset = 0

  for (const entry of entries) {
    const { name, compressed, header, crc } = localPart(entry, stamp)
    parts.push(header, name, compressed)

    const dir = Buffer.alloc(46)
    dir.writeUInt32LE(0x02014b50, 0) // central directory header
    dir.writeUInt16LE(20, 4) // made by 2.0
    dir.writeUInt16LE(20, 6) // needed 2.0
    dir.writeUInt16LE(0, 8)
    dir.writeUInt16LE(8, 10)
    dir.writeUInt16LE(stamp.time, 12)
    dir.writeUInt16LE(stamp.date, 14)
    dir.writeUInt32LE(crc, 16)
    dir.writeUInt32LE(compressed.length, 20)
    dir.writeUInt32LE(entry.data.length, 24)
    dir.writeUInt16LE(name.length, 28)
    dir.writeUInt16LE(0, 30) // extra
    dir.writeUInt16LE(0, 32) // comment
    dir.writeUInt16LE(0, 34) // disk
    dir.writeUInt16LE(0, 36) // internal attributes
    dir.writeUInt32LE(0, 38) // external attributes
    dir.writeUInt32LE(offset, 42)
    central.push(dir, name)

    offset += header.length + name.length + compressed.length
  }

  const directory = Buffer.concat(central)
  const end = Buffer.alloc(22)
  end.writeUInt32LE(0x06054b50, 0) // end of central directory
  end.writeUInt16LE(0, 4) // this disk
  end.writeUInt16LE(0, 6) // disk with the directory
  end.writeUInt16LE(entries.length, 8)
  end.writeUInt16LE(entries.length, 10)
  end.writeUInt32LE(directory.length, 12)
  end.writeUInt32LE(offset, 16)
  end.writeUInt16LE(0, 20) // no comment

  return Buffer.concat([...parts, directory, end])
}
