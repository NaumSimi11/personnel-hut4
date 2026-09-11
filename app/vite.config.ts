/// <reference types="vitest/config" />
import { fileURLToPath, URL } from 'node:url'
import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'

export default defineConfig({
  plugins: [vue()],
  // Reuse the repo-root .env.local; Vite only exposes VITE_-prefixed vars,
  // so the server-only secrets in that file never reach the bundle.
  envDir: '../',
  resolve: {
    alias: {
      '@': fileURLToPath(new URL('./src', import.meta.url)),
      '@shared': fileURLToPath(new URL('../shared', import.meta.url)),
    },
  },
  server: {
    // The privileged auth endpoints (invite / reset / change password) live in
    // ../server — same-origin in dev via this proxy.
    proxy: { '/api': 'http://127.0.0.1:8787' },
  },
  // Unit tests only — Playwright owns e2e/.
  test: { include: ['src/**/*.test.ts'] },
})
