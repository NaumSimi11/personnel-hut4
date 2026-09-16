<script setup lang="ts">
import ChecklistQueue from '@/components/checklists/ChecklistQueue.vue'
</script>

<template>
  <div>
    <div class="page-head">
      <div>
        <div class="eyebrow">HR operations</div>
        <h1>Make the first day feel prepared.</h1>
      </div>
    </div>
    <ChecklistQueue kind="onboarding" />
  </div>
</template>

<style scoped>
.page-head { display: flex; align-items: center; justify-content: space-between; gap: 16px; flex-wrap: wrap; }
h1 { margin-bottom: 24px; }
</style>
