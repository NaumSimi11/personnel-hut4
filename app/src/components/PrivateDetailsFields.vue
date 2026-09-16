<script setup lang="ts">
/**
 * The nine private-detail inputs — birth date, address, national ID, bank,
 * account, emergency contact (name, relationship, phone), notes — bound to
 * one form object. Shared by the Add employee dialog and the Private
 * details card (plan 046), so the labels and limits live once. `prefix`
 * keeps the ids unique when both are on a page.
 */
export type PrivateDetailsForm = {
  birthDate: string
  addressLine: string
  nationalId: string
  bankName: string
  bankAccountNumber: string
  emergencyName: string
  emergencyRelationship: string
  emergencyPhone: string
  notes: string
}

const props = defineProps<{ modelValue: PrivateDetailsForm; prefix: string }>()
const emit = defineEmits<{ 'update:modelValue': [value: PrivateDetailsForm] }>()

function set<K extends keyof PrivateDetailsForm>(key: K, value: string): void {
  emit('update:modelValue', { ...props.modelValue, [key]: value })
}

function id(name: string): string {
  return `${props.prefix}-${name}`
}
</script>

<template>
  <div class="grid">
    <div class="field">
      <label :for="id('birth')">Date of birth</label>
      <input :id="id('birth')" :value="modelValue.birthDate" type="date" @input="set('birthDate', ($event.target as HTMLInputElement).value)" />
    </div>
    <div class="field">
      <label :for="id('national-id')">National ID number</label>
      <input :id="id('national-id')" :value="modelValue.nationalId" maxlength="32" autocomplete="off" @input="set('nationalId', ($event.target as HTMLInputElement).value)" />
    </div>
    <div class="field wide">
      <label :for="id('address')">Home address</label>
      <input :id="id('address')" :value="modelValue.addressLine" maxlength="200" @input="set('addressLine', ($event.target as HTMLInputElement).value)" />
    </div>
    <div class="field">
      <label :for="id('bank')">Bank</label>
      <input :id="id('bank')" :value="modelValue.bankName" maxlength="80" @input="set('bankName', ($event.target as HTMLInputElement).value)" />
    </div>
    <div class="field">
      <label :for="id('account')">Account number / IBAN</label>
      <input :id="id('account')" :value="modelValue.bankAccountNumber" maxlength="40" autocomplete="off" @input="set('bankAccountNumber', ($event.target as HTMLInputElement).value)" />
    </div>
    <div class="field">
      <label :for="id('emergency-name')">Emergency contact</label>
      <input :id="id('emergency-name')" :value="modelValue.emergencyName" maxlength="120" @input="set('emergencyName', ($event.target as HTMLInputElement).value)" />
    </div>
    <div class="field">
      <label :for="id('emergency-relationship')">Relationship</label>
      <input :id="id('emergency-relationship')" :value="modelValue.emergencyRelationship" maxlength="60" placeholder="e.g. spouse, brother" @input="set('emergencyRelationship', ($event.target as HTMLInputElement).value)" />
    </div>
    <div class="field">
      <label :for="id('emergency-phone')">Emergency phone</label>
      <input :id="id('emergency-phone')" :value="modelValue.emergencyPhone" maxlength="40" @input="set('emergencyPhone', ($event.target as HTMLInputElement).value)" />
    </div>
    <div class="field wide">
      <label :for="id('notes')">Notes</label>
      <textarea :id="id('notes')" :value="modelValue.notes" rows="2" maxlength="2000" @input="set('notes', ($event.target as HTMLTextAreaElement).value)"></textarea>
    </div>
  </div>
</template>

<style scoped>
.grid { display: grid; grid-template-columns: 1fr 1fr; gap: 0 14px; }
.grid .wide { grid-column: 1 / -1; }
@media (max-width: 560px) { .grid { grid-template-columns: 1fr; } }
.field textarea {
  width: 100%;
  border: 1px solid #dce3d7;
  padding: 11px 12px;
  background: #fff;
  color: var(--ink);
  font-size: 12px;
  font-family: inherit;
  resize: vertical;
}
</style>
