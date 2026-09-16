<script setup lang="ts">
// Root shell: routing decides between the login page and the app layout.
// AppDialogs is the one question box every page asks through (plan 046).
import AppDialogs from '@/components/AppDialogs.vue'
</script>

<template>
  <router-view />
  <AppDialogs />
</template>
