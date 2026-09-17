import { describe, expect, it } from 'vitest'
import { nextAssetTag, nextInventoryNumber } from './assetNumbering'

describe('nextAssetTag', () => {
  it('continues the series a company already uses', () => {
    expect(nextAssetTag(['A001', 'A002', 'A009'])).toBe('A010')
  })

  it('keeps the width the series was written with', () => {
    expect(nextAssetTag(['0000001', '0000014'])).toBe('0000015')
  })

  it('follows the prefix used most, not whichever sorts last', () => {
    // Synami runs A… for laptops and B… for desktops; the next laptop should
    // not be named after the desktops.
    expect(nextAssetTag(['A001', 'A002', 'A003', 'B001'])).toBe('A004')
  })

  it('ignores tags that carry no number', () => {
    expect(nextAssetTag(['A001', 'SPARE', 'A002'])).toBe('A003')
  })

  it('ignores a suffix that is not part of the series', () => {
    expect(nextAssetTag(['A001', 'B006-HDD', 'A002'])).toBe('A003')
  })

  it('suggests nothing when there is no series to continue', () => {
    expect(nextAssetTag([])).toBeNull()
    expect(nextAssetTag(['SPARE', 'OLD'])).toBeNull()
  })
})

describe('nextInventoryNumber', () => {
  it('takes the highest and adds one', () => {
    expect(nextInventoryNumber(['71', '10', '121'])).toBe('122')
  })

  it('ignores blanks and anything not a number', () => {
    expect(nextInventoryNumber(['71', null, '', 'n/a', '93'])).toBe('94')
  })

  it('suggests nothing when none has been recorded', () => {
    expect(nextInventoryNumber([])).toBeNull()
    expect(nextInventoryNumber([null, ''])).toBeNull()
  })
})
