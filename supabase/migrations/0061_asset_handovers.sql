-- 0061_asset_handovers.sql
-- One record for an asset changing hands, whoever started it.
--
-- equipment_returns (0050) described a person handing something back to HR.
-- Reassigning is the same event pointed the other way: HR takes it from one
-- person and gives it to another, and both acts want the same document, the
-- same two signatures and the same rule that nobody completes a handover alone.
-- Building that beside the return would be the mistake already made once with
-- the two equipment rows, which drifted apart the moment one was improved.
--
-- So the return becomes a kind of handover. equipment_returns is empty — the
-- only rows it ever held were test rows, removed — so nothing is migrated and
-- nothing is lost.
--
--   kind 'return'   someone gives what they hold back to the company
--   kind 'issue'    the company gives something to someone
--   kind 'reassign' it moves from one person to another in one act
--
-- from_person_id null means it was in magacin; to_person_id null means it is
-- going there. The asset does not move until the receiving side signs: a
-- handover one party can finish alone is how equipment goes missing with the
-- paperwork saying otherwise.

drop table if exists public.equipment_returns cascade;

create table public.asset_handovers (
  id uuid primary key default gen_random_uuid(),
  asset_id uuid not null references public.assets(id) on delete cascade,
  company_id uuid not null references public.companies(id),
  kind text not null check (kind in ('return', 'issue', 'reassign')),

  from_person_id uuid references public.people(id),   -- null = it was in magacin
  to_person_id uuid references public.people(id),     -- null = it is going to magacin
  -- Who must put their name to it opposite the person who started it.
  counterparty_id uuid not null references public.people(id),
  started_by uuid not null references public.people(id),

  reason text,
  condition text,
  status text not null default 'awaiting'
    check (status in ('awaiting', 'accepted', 'declined', 'cancelled')),
  decline_reason text,

  signed_by_starter_at timestamptz,
  signed_by_counterparty_at timestamptz,
  signed_by_counterparty uuid references public.people(id),

  document_id uuid references public.documents(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index asset_handovers_asset_idx on public.asset_handovers (asset_id, status);
create index asset_handovers_waiting_idx on public.asset_handovers (counterparty_id) where status = 'awaiting';
-- One in flight per asset: two people cannot hand the same thing over at once.
create unique index one_open_handover_per_asset on public.asset_handovers (asset_id)
  where status = 'awaiting';

create trigger touch before update on public.asset_handovers
  for each row execute function app.touch_updated_at();

alter table public.asset_handovers enable row level security;

create policy sel on public.asset_handovers for select to authenticated
  using (
    app.is_self(started_by)
    or app.is_self(counterparty_id)
    or app.is_self(from_person_id)
    or app.is_self(to_person_id)
    or app.can_work_asset(company_id, 'it.view')
  );

-- Started through the RPCs below, which decide who may start which kind.
create policy upd on public.asset_handovers for update to authenticated
  using (app.is_self(counterparty_id) or app.can_work_asset(company_id, 'it.assign'))
  with check (app.is_self(counterparty_id) or app.can_work_asset(company_id, 'it.assign'));

comment on table public.asset_handovers is
  'An asset changing hands: return, issue or reassign. Not complete until both names are on it.';
