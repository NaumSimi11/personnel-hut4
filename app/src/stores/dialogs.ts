import { ref } from 'vue'
import { defineStore } from 'pinia'
import {
  createDialogQueue,
  type ConfirmRequest,
  type Pending,
  type ReasonAnswer,
  type ReasonRequest,
} from '@/lib/dialogs'

/**
 * The app's one question box (plan 046). Components call
 * `confirmAction()` / `askReason()` and await the answer; AppDialogs, mounted
 * once in App.vue, renders whatever is current.
 */
export const useDialogStore = defineStore('dialogs', () => {
  const queue = createDialogQueue()
  const current = ref<Pending | null>(null)
  queue.subscribe((p) => {
    current.value = p
  })

  /** True when the person confirmed. */
  function confirmAction(request: Omit<ConfirmRequest, 'kind'>): Promise<boolean> {
    return queue.ask<boolean>({ kind: 'confirm', ...request })
  }

  /** The reason (and number, when asked for), or null when cancelled. */
  function askReason(request: Omit<ReasonRequest, 'kind'>): Promise<ReasonAnswer | null> {
    return queue.ask<ReasonAnswer | null>({ kind: 'reason', ...request })
  }

  function settle(answer: unknown): void {
    queue.settle(answer)
  }

  return { current, confirmAction, askReason, settle }
})
