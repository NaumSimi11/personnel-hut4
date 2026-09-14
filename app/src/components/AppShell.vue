<script setup lang="ts">
import AvatarImage from '@/components/AvatarImage.vue'
import { useNotificationsStore } from '@/stores/notifications'
import { onMounted, onUnmounted } from 'vue'
import { useRouter } from 'vue-router'
import { useAuthStore } from '@/stores/auth'

const auth = useAuthStore()
const router = useRouter()
const notifications = useNotificationsStore()

// The bell: my unread notifications, refreshed every minute while signed in.
onMounted(() => notifications.start())
onUnmounted(() => notifications.stop())

async function signOut() {
  notifications.stop()
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
        <router-link :to="{ name: 'companies' }">Companies</router-link>
        <router-link :to="{ name: 'directory' }">People &amp; access</router-link>
        <router-link :to="{ name: 'hiring' }">Hiring</router-link>
        <router-link :to="{ name: 'reports' }">Reports</router-link>
        <router-link :to="{ name: 'onboarding' }">Onboarding</router-link>
        <router-link :to="{ name: 'offboarding' }">Offboarding</router-link>
        <router-link :to="{ name: 'leave' }">Leave</router-link>
        <router-link :to="{ name: 'my-workspace' }">My workspace</router-link>
        <router-link :to="{ name: 'notifications' }" class="bell" data-testid="nav-notifications">
          <svg width="15" height="15" viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M4 11V7a4 4 0 0 1 8 0v4l1.5 1.5H2.5z" /><path d="M6.5 14a1.5 1.5 0 0 0 3 0" /></svg>
          Notifications
          <span v-if="notifications.unread" class="unread" data-testid="unread-count">{{ notifications.unread }}</span>
        </router-link>
      </nav>
      <div class="sidebar-bottom">
        <AvatarImage :name="auth.personName ?? 'U'" :path="auth.avatarPath" size="small" />
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
  background: linear-gradient(180deg, #17392f 0%, var(--sidebar) 55%, #0f2820 100%);
  color: #d4e0d8;
  padding: 33px 18px 24px;
  position: fixed;
  inset: 0 auto 0 0;
  display: flex;
  flex-direction: column;
  box-shadow: inset -1px 0 0 rgba(255, 255, 255, 0.04), 8px 0 40px -30px rgba(15, 40, 32, 0.6);
}
.brand {
  display: flex;
  align-items: center;
  gap: 12px;
  color: #fff;
  font-size: 21px;
  font-weight: 700;
  letter-spacing: -0.02em;
  margin: 0 8px 38px;
}
.brand small { font-size: 11px; font-weight: 400; display: block; color: #9fb7aa; margin-top: 4px; letter-spacing: 0.02em; }
.brand-mark {
  background: linear-gradient(145deg, #e6f0d3, #bfd8c4);
  color: var(--sidebar);
  width: 40px;
  height: 44px;
  border-radius: 12px;
  display: grid;
  place-items: center;
  font-size: 26px;
  box-shadow: 0 8px 20px -10px rgba(0, 0, 0, 0.6), inset 0 1px 0 rgba(255, 255, 255, 0.6);
}
nav { display: grid; gap: 4px; }
nav a {
  position: relative;
  display: flex;
  align-items: center;
  padding: 11px 14px 11px 18px;
  border-radius: 10px;
  text-decoration: none;
  color: #b7cabe;
  font-size: 13.5px;
  font-weight: 500;
  transition: background 0.18s var(--ease), color 0.18s var(--ease), transform 0.18s var(--ease);
}
nav a::before {
  content: '';
  position: absolute;
  left: 6px;
  top: 50%;
  width: 3px;
  height: 0;
  border-radius: 3px;
  background: linear-gradient(180deg, var(--gold), #7fd1b1);
  transform: translateY(-50%);
  transition: height 0.22s var(--ease);
}
nav a:hover { background: rgba(255, 255, 255, 0.06); color: #fff; }
nav a.router-link-active {
  color: #fff;
  background: linear-gradient(90deg, rgba(255, 255, 255, 0.12), rgba(255, 255, 255, 0.05));
  box-shadow: inset 0 0 0 1px rgba(255, 255, 255, 0.08);
}
nav a.router-link-active::before { height: 18px; }
nav a.bell { gap: 9px; margin-top: 6px; }
.unread { margin-left: auto; display: inline-grid; place-items: center; min-width: 22px; height: 20px; padding: 0 7px; border-radius: 999px; background: var(--gold); color: #1b2a22; font-size: 11px; font-weight: 700; }
.sidebar-bottom { margin-top: auto; display: flex; align-items: center; gap: 10px; padding: 12px 10px; border-radius: 12px; background: rgba(255, 255, 255, 0.05); }
.sidebar-bottom strong { font-weight: 600; font-size: 12.5px; display: block; color: #fff; }
.avatar-dark { background: linear-gradient(145deg, #4d7a62, #2f5646); color: #e7f2e8; box-shadow: none; }
.linkish {
  background: none;
  border: 0;
  color: #9fb7aa;
  font-size: 11px;
  padding: 2px 0;
  text-decoration: underline;
  text-underline-offset: 2px;
}
.linkish:hover { color: #fff; }
.workspace { margin-left: 236px; flex: 1; min-width: 0; padding: 35px 42px 50px; }
@media (max-width: 720px) {
  .sidebar { position: static; width: auto; box-shadow: none; }
  .shell { display: block; }
  .workspace { margin: 0; padding: 20px 16px; }
}
</style>
