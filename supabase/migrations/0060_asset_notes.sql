-- 0060_asset_notes.sql
-- What has happened to a thing, in the order it happened.
--
-- An asset's past was scattered: assignments say who held it, equipment_returns
-- say how it came back, transfers (when they exist) say which company owns it —
-- and nothing at all recorded that the screen was replaced in March, or that it
-- was dropped, or why it is marked damaged. A попис asks "what is this and what
-- state is it in", and the answer lived in somebody's memory.
--
-- A note is written and never edited. The point of a service history is that it
-- is a record rather than a description: a line that can be rewritten later
-- tells you what someone thinks now, not what happened then. Corrections are
-- new lines, as they would be in a logbook.

create table public.asset_notes (
  id uuid primary key default gen_random_uuid(),
  asset_id uuid not null references public.assets(id) on delete cascade,
  kind text not null default 'note'
    check (kind in ('note', 'service', 'damage', 'condition')),
  body text not null,
  -- The person it concerned, when it concerned one — a repair while X held it.
  about_person_id uuid references public.people(id),
  happened_on date not null default current_date,
  written_by uuid references public.people(id),
  created_at timestamptz not null default now()
);
create index asset_notes_asset_idx on public.asset_notes (asset_id, happened_on desc);

alter table public.asset_notes enable row level security;

-- The same gate as the asset itself: if you may see the thing, you may read its
-- history, and if you may work it you may add to that history.
create policy sel on public.asset_notes for select to authenticated
  using (exists (
    select 1 from public.assets a where a.id = asset_id and app.can_see_asset(a.company_id)));

create policy ins on public.asset_notes for insert to authenticated
  with check (exists (
    select 1 from public.assets a where a.id = asset_id and app.can_work_asset(a.company_id, 'it.assign')));

-- No update, no delete policy: a note is written once. Postgres denies what no
-- policy allows, so this is the rule rather than a convention.

comment on table public.asset_notes is
  'An asset''s service history. Written once — a correction is a new line, as in a logbook.';
