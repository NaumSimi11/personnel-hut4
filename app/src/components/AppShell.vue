<script setup lang="ts">
import { useRouter } from 'vue-router'
import { useAuthStore } from '@/stores/auth'

const auth = useAuthStore()
const router = useRouter()

async function signOut() {
  await auth.signOut()
  router.push({ name: 'login' })
}
</script>

<template>
  <div class="shell">
    <aside class="sidebar">
      <div class="brand">
        <span class="brand-mark">p.</span>
        <span>Personnel<small>Hut4 workspace</small></span>
      </div>
      <nav aria-label="Workspace">
        <router-link :to="{ name: 'overview' }">Overview</router-link>
        <router-link :to="{ name: 'directory' }">People &amp; access</router-link>
        <router-link :to="{ name: 'hiring' }">Hiring</router-link>
        <router-link :to="{ name: 'onboarding' }">Onboarding</router-link>
        <router-link :to="{ name: 'my-workspace' }">My workspace</router-link>
      </nav>
      <div class="sidebar-bottom">
        <span class="avatar avatar-dark">{{ (auth.personName ?? 'U')[0] }}</span>
        <div>
          <strong>{{ auth.personName ?? auth.session?.user.email }}</strong>
          <button class="linkish" @click="signOut">Sign out</button>
        </div>
      </div>
    </aside>
    <main class="workspace">
      <router-view />
    </main>
  </div>
</template>

<style scoped>
.shell { display: flex; min-height: 100vh; }
.sidebar {
  width: 236px;
  background: var(--sidebar);
  color: #d4e0d8;
  padding: 33px 20px 24px;
  position: fixed;
  inset: 0 auto 0 0;
  display: flex;
  flex-direction: column;
}
.brand {
  display: flex;
  align-items: center;
  gap: 12px;
  color: #fff;
  font-size: 21px;
  font-weight: 750;
  margin: 0 10px 40px;
}
.brand small { font-size: 11px; font-weight: 400; display: block; color: #a7bdb0; margin-top: 5px; }
.brand-mark {
  background: #d6e4bd;
  color: var(--sidebar);
  width: 38px;
  height: 42px;
  border-radius: 11px;
  display: grid;
  place-items: center;
  font-size: 27px;
}
nav { display: grid; gap: 6px; }
nav a {
  display: flex;
  align-items: center;
  padding: 13px 14px;
  border-radius: 9px;
  text-decoration: none;
  color: #bbcec2;
  font-size: 13px;
}
nav a:hover { background: #22493c; }
nav a.router-link-active { color: #fff; background: #315647; }
.sidebar-bottom { margin-top: auto; display: flex; align-items: center; gap: 10px; }
.sidebar-bottom strong { font-weight: 500; font-size: 12px; display: block; }
.avatar-dark { background: #45624f; color: #dfebd6; }
.linkish {
  background: none;
  border: 0;
  color: #99b4a3;
  font-size: 10px;
  padding: 2px 0;
  text-decoration: underline;
}
.workspace { margin-left: 236px; flex: 1; min-width: 0; padding: 35px 42px 50px; }
@media (max-width: 720px) {
  .sidebar { position: static; width: auto; }
  .shell { display: block; }
  .workspace { margin: 0; padding: 20px 16px; }
}
</style>
