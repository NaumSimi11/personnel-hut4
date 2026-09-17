<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { signatureProblem, type SignatureInput, type SignatureMethod } from '@shared/signature'

/**
 * Putting your name to something, without a signing service.
 *
 * Two ways, because people differ: type it and it renders in a script face, or
 * draw it with a finger or mouse. Typing is the honest default — on a laptop a
 * drawn signature is a worse version of the same legal act, and most people
 * produce an unrecognisable scrawl with a trackpad.
 *
 * The statement above the pad is the point of the component. A signature under
 * "I agree" is worth little; one under a sentence saying exactly what is being
 * agreed is worth something, so the sentence is shown, not hidden behind a link.
 */
const props = defineProps<{
  /** The exact sentence being agreed to. Shown in full, never truncated. */
  statement: string
  /** How the signer is acting — for themselves, or for a company. */
  capacity: string
  /** Pre-fills the typed name with the person's own, which they may correct. */
  suggestedName: string
  busy?: boolean
}>()

const emit = defineEmits<{ sign: [SignatureInput] }>()

const method = ref<SignatureMethod>('typed')
const name = ref(props.suggestedName)
const image = ref<string | null>(null)
const agreed = ref(false)
const canvas = ref<HTMLCanvasElement | null>(null)
const drawing = ref(false)

const input = computed<SignatureInput>(() => ({ method: method.value, name: name.value, image: image.value }))
const problem = computed(() => signatureProblem(input.value))
const ready = computed(() => agreed.value && problem.value === null && !props.busy)

function positionOf(event: PointerEvent): { x: number; y: number } {
  const box = canvas.value!.getBoundingClientRect()
  return {
    x: (event.clientX - box.left) * (canvas.value!.width / box.width),
    y: (event.clientY - box.top) * (canvas.value!.height / box.height),
  }
}

function start(event: PointerEvent): void {
  if (!canvas.value) return
  drawing.value = true
  canvas.value.setPointerCapture(event.pointerId)
  const ctx = canvas.value.getContext('2d')!
  const at = positionOf(event)
  ctx.beginPath()
  ctx.moveTo(at.x, at.y)
}

function move(event: PointerEvent): void {
  if (!drawing.value || !canvas.value) return
  const ctx = canvas.value.getContext('2d')!
  const at = positionOf(event)
  ctx.lineWidth = 2.2
  ctx.lineCap = 'round'
  ctx.lineJoin = 'round'
  ctx.strokeStyle = '#1d2b1f'
  ctx.lineTo(at.x, at.y)
  ctx.stroke()
}

function end(): void {
  if (!drawing.value || !canvas.value) return
  drawing.value = false
  image.value = canvas.value.toDataURL('image/png')
}

function clear(): void {
  if (!canvas.value) return
  const ctx = canvas.value.getContext('2d')!
  ctx.clearRect(0, 0, canvas.value.width, canvas.value.height)
  image.value = null
}

// Switching away from drawing throws the drawing away rather than keeping a
// mark the person can no longer see.
watch(method, (now) => { if (now === 'typed') clear() })

function submit(): void {
  if (!ready.value) return
  emit('sign', input.value)
}
</script>

<template>
  <div class="pad">
    <p class="statement">{{ statement }}</p>
    <p class="capacity">Signing as: <strong>{{ capacity }}</strong></p>

    <div class="methods" role="tablist">
      <button type="button" role="tab" :aria-selected="method === 'typed'" :class="{ on: method === 'typed' }" @click="method = 'typed'">Type it</button>
      <button type="button" role="tab" :aria-selected="method === 'drawn'" :class="{ on: method === 'drawn' }" @click="method = 'drawn'">Draw it</button>
    </div>

    <label class="name">
      <span>Your full name</span>
      <input v-model="name" maxlength="120" autocomplete="name" />
    </label>

    <div v-if="method === 'typed'" class="preview" aria-label="Your signature as it will appear">
      <span class="script">{{ name || ' ' }}</span>
    </div>

    <div v-else class="draw">
      <canvas
        ref="canvas"
        width="600"
        height="180"
        @pointerdown.prevent="start"
        @pointermove.prevent="move"
        @pointerup.prevent="end"
        @pointerleave="end"
      ></canvas>
      <button type="button" class="button secondary small-btn" @click="clear">Clear</button>
    </div>

    <label class="agree">
      <input v-model="agreed" type="checkbox" />
      <span>I have read the statement above and I am signing it.</span>
    </label>

    <p v-if="problem && (agreed || image || name)" class="problem">{{ problem }}</p>

    <div class="actions">
      <slot name="cancel" />
      <button type="button" class="button small-btn" :disabled="!ready" @click="submit">
        {{ busy ? 'Signing…' : 'Sign' }}
      </button>
    </div>

    <p class="fineprint">
      Your name, the time, and your browser and network address are recorded with this signature.
    </p>
  </div>
</template>

<style scoped>
.pad { display: grid; gap: 12px; }
.statement { margin: 0; padding: 12px 14px; border-radius: 9px; background: var(--green-soft); color: var(--green); font-size: 12px; line-height: 1.55; }
.capacity { margin: 0; font-size: 11px; color: var(--muted); }
.methods { display: flex; gap: 6px; }
.methods button { font: inherit; font-size: 11px; padding: 6px 12px; border: 1px solid var(--line); background: #fff; border-radius: 999px; cursor: pointer; color: var(--muted); }
.methods button.on { border-color: var(--green); color: var(--green); font-weight: 600; }
.name { display: grid; gap: 4px; font-size: 11px; color: var(--muted); }
.name input { font: inherit; font-size: 13px; padding: 8px 10px; border: 1px solid var(--line); border-radius: 8px; }
.preview { display: grid; place-items: center; min-height: 86px; border: 1px dashed var(--line); border-radius: 10px; background: #fff; }
/* A script face the browser already has, so a signature never waits on a font. */
.script { font-family: 'Snell Roundhand', 'Apple Chancery', 'Segoe Script', 'Brush Script MT', cursive; font-size: 34px; color: #1d2b1f; }
.draw { display: grid; gap: 8px; justify-items: start; }
.draw canvas { width: 100%; max-width: 600px; height: 180px; border: 1px dashed var(--line); border-radius: 10px; background: #fff; touch-action: none; cursor: crosshair; }
.agree { display: flex; align-items: flex-start; gap: 9px; font-size: 12px; }
.problem { margin: 0; font-size: 11px; color: #a8332b; }
.actions { display: flex; gap: 8px; justify-content: flex-end; }
.fineprint { margin: 0; font-size: 10px; color: var(--muted); }
</style>
