-- 0050_equipment_self_service.sql
-- Asking for equipment, and handing it back, from a person's own page.
--
-- Until now both ends of equipment were IT's: IT registered an asset, IT issued
-- it, and a return happened because a departure was scheduled. A person who
-- simply wanted a second monitor, or who was finished with a laptop, had no way
-- to say so inside the app — so they said it in a corridor, and the register
-- drifted from reality. That drift is what a попис then has to discover.
--
-- Two flows, both ending in a signed document:
--
--   Asking      → an it_request of kind 'manual', raised by the person. That
--                 table already exists and IT already works from it; nothing
--                 new is needed beyond letting a person insert their own.
--
--   Returning   → equipment_returns below. The person names who in HR should
--                 receive it, the app makes the return form, and the return is
--                 not finished until BOTH sides have put their name to it. The
--                 asset stays with the person until HR accepts: a return that
--                 one side can complete alone is how equipment goes missing
--                 with the paperwork saying otherwise.
--
-- On signatures: the signed_* columns record who put their name to it and when.
-- How that name is captured is deliberately not encoded here — today it is the
-- app's own confirmation plus the signed PDF, and it may become an external
-- e-signature service. Either way it is the same three facts, so swapping the
-- mechanism does not migrate this table.

create table public.equipment_returns (
  id uuid primary key default gen_random_uuid(),
  asset_id uuid not null references public.assets(id) on delete cascade,
  assignment_id uuid references public.asset_assignments(id) on delete set null,
  company_id uuid not null references public.companies(id),
  -- who is giving it back
  person_id uuid not null references public.people(id) on delete cascade,
  -- who in HR they sent it to
  hr_person_id uuid not null references public.people(id),
  reason text,
  condition text,
  status text not null default 'awaiting_hr'
    check (status in ('awaiting_hr', 'accepted', 'declined', 'cancelled')),
  decline_reason text,

  -- the two names on the document
  signed_by_person_at timestamptz,
  signed_by_hr_at timestamptz,
  signed_by_hr uuid references public.people(id),

  document_id uuid references public.documents(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index equipment_returns_person_idx on public.equipment_returns (person_id, status);
create index equipment_returns_hr_idx on public.equipment_returns (hr_person_id) where status = 'awaiting_hr';
-- One open return per asset: two people cannot hand the same thing back at once.
create unique index one_open_return_per_asset on public.equipment_returns (asset_id)
  where status = 'awaiting_hr';

create trigger touch before update on public.equipment_returns
  for each row execute function app.touch_updated_at();

alter table public.equipment_returns enable row level security;

-- You see your own returns; HR sees what was sent to them; anyone who may work
-- the company's equipment sees them all.
create policy sel on public.equipment_returns for select to authenticated
  using (
    app.is_self(person_id)
    or app.is_self(hr_person_id)
    or app.can_work_asset(company_id, 'it.view')
  );

-- You may start a return of something you hold. Nobody may start one for you:
-- the point of the document is that you said you were handing it back.
create policy ins on public.equipment_returns for insert to authenticated
  with check (
    app.is_self(person_id)
    and exists (
      select 1 from public.asset_assignments a
      where a.asset_id = equipment_returns.asset_id
        and a.person_id = equipment_returns.person_id
        and a.returned_at is null
    )
  );

-- The named HR person decides, and so may anyone who can work the equipment.
create policy upd on public.equipment_returns for update to authenticated
  using (app.is_self(hr_person_id) or app.can_work_asset(company_id, 'it.assign'))
  with check (app.is_self(hr_person_id) or app.can_work_asset(company_id, 'it.assign'));

comment on table public.equipment_returns is
  'A person handing equipment back, awaiting an HR name on the same document.';
