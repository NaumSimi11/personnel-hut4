import { describe, expect, it } from 'vitest'
import { platformAdminControl } from './platformAdmin'

describe('platform admin control', () => {
  it('offers to make a non-admin an admin', () => {
    expect(platformAdminControl({ isAdmin: false, isSelf: false, admins: 1 })).toEqual({
      action: 'grant',
      label: 'Make platform admin',
      disabled: false,
      reason: null,
    })
  })

  it('offers to remove an admin while another admin remains', () => {
    expect(platformAdminControl({ isAdmin: true, isSelf: false, admins: 2 })).toEqual({
      action: 'revoke',
      label: 'Remove platform admin',
      disabled: false,
      reason: null,
    })
  })

  it('never lets you remove yourself, and never the last admin', () => {
    expect(platformAdminControl({ isAdmin: true, isSelf: true, admins: 2 })).toMatchObject({
      action: 'revoke',
      disabled: true,
      reason: 'Ask another platform admin to remove you.',
    })
    expect(platformAdminControl({ isAdmin: true, isSelf: false, admins: 1 })).toMatchObject({
      action: 'revoke',
      disabled: true,
      reason: 'The last platform admin cannot be removed.',
    })
  })
})
