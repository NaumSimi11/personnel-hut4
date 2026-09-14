<script setup lang="ts">
/**
 * The headline numbers of the Home (plan 044). Which tiles appear is the
 * page's call — by what the viewer may see — so this only lays them out.
 */
export type StatTile = { key: string; label: string; value: string | number; sub?: string; tone?: 'hot' | 'gold' }

defineProps<{ tiles: StatTile[]; loading?: boolean }>()
</script>

<template>
  <div class="stats" data-testid="dashboard-stats">
    <div v-for="t in tiles" :key="t.key" class="stat" :class="t.tone" :data-testid="`stat-${t.key}`">
      <b>{{ loading ? '…' : t.value }}</b>
      <span>{{ t.label }}</span>
      <small v-if="t.sub && !loading">{{ t.sub }}</small>
    </div>
  </div>
</template>

<style scoped>
.stats { display: grid; grid-template-columns: repeat(auto-fit, minmax(190px, 1fr)); gap: 14px; margin-bottom: 22px; }
.stat {
  background: var(--surface);
  border: 1px solid var(--line);
  border-radius: var(--radius);
  padding: 16px 20px;
  box-shadow: var(--shadow-sm);
  display: grid;
  gap: 3px;
  align-content: start;
}
.stat b { font-size: 26px; font-weight: 700; letter-spacing: -0.03em; line-height: 1.1; }
.stat span { font-size: 12px; color: var(--muted); font-weight: 550; }
.stat small { font-size: 11px; color: var(--muted); }
.stat.hot { border-color: #ead9b3; background: linear-gradient(135deg, #fff, #fdf7e9); }
.stat.hot b { color: var(--amber); }
.stat.gold { border-color: #dfe9dd; background: linear-gradient(135deg, #fff, var(--green-soft)); }
.stat.gold b { color: var(--green); }
</style>
