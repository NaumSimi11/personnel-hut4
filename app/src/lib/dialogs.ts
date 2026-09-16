/**
 * In-app questions (plan 046): every "are you sure?" and every "why?" the
 * app asks goes through one queue that AppDialogs renders — never
 * window.confirm / window.prompt, which cannot validate, show context or be
 * styled. Framework-free so the rules are unit-tested; stores/dialogs.ts
 * wraps it for components.
 */

export type ValueSpec = {
  label: string
  initial?: number
  min?: number
}

export type ReasonRequest = {
  kind: 'reason'
  title: string
  eyebrow?: string
  hint?: string
  /** Label of the text field; "Reason" when absent. */
  label?: string
  /** A reason is required unless said otherwise. */
  required?: boolean
  initial?: string
  /** Ask for a whole number too (the leave entitlement, an adjustment). */
  value?: ValueSpec
  confirmLabel?: string
  danger?: boolean
}

export type ConfirmRequest = {
  kind: 'confirm'
  title: string
  eyebrow?: string
  hint?: string
  confirmLabel?: string
  cancelLabel?: string
  danger?: boolean
}

export type DialogRequest = ReasonRequest | ConfirmRequest

export type ReasonAnswer = { reason: string; value: number | null }

export type Pending = {
  id: number
  request: DialogRequest
  settle: (answer: unknown) => void
}

type Listener = (current: Pending | null) => void

export type DialogQueue = {
  ask<T>(request: DialogRequest): Promise<T>
  settle(answer: unknown): void
  current(): Pending | null
  subscribe(listener: Listener): () => void
}

/** One question at a time; the next one waits until the current is settled. */
export function createDialogQueue(): DialogQueue {
  let waiting: Pending[] = []
  let open: Pending | null = null
  let listeners: Listener[] = []
  let nextId = 1

  function notify(): void {
    for (const l of listeners) l(open)
  }

  function advance(): void {
    const [head, ...rest] = waiting
    waiting = rest
    open = head ?? null
    notify()
  }

  return {
    ask<T>(request: DialogRequest): Promise<T> {
      return new Promise<T>((resolve) => {
        const pending: Pending = { id: nextId++, request, settle: (answer) => resolve(answer as T) }
        waiting = [...waiting, pending]
        if (!open) advance()
      })
    },
    settle(answer: unknown): void {
      if (!open) return
      const done = open
      advance()
      done.settle(answer)
    },
    current(): Pending | null {
      return open
    },
    subscribe(listener: Listener): () => void {
      listeners = [...listeners, listener]
      return () => {
        listeners = listeners.filter((l) => l !== listener)
      }
    },
  }
}

/** What stops a reason answer from being sent; null when it may go. */
export function validateReason(request: ReasonRequest, reason: string, value: number | null): string | null {
  const required = request.required !== false
  if (required && reason.trim().length === 0) {
    return `${request.label ?? 'A reason'} is needed — it is recorded.`
  }
  if (request.value) {
    if (value === null || Number.isNaN(value)) return `${request.value.label} is needed.`
    if (request.value.min !== undefined && value < request.value.min) {
      return `${request.value.label} cannot be below ${request.value.min}.`
    }
  }
  return null
}
