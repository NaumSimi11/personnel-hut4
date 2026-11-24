-- 0130 — the yearly equipment check, and warranties on an item (24 Nov).
--
--  * The General Administrator runs equipment: the role gains it.view and
--    it.assign (and grants made from it).
--  * Equipment check: the General Administrator starts one per company with a
--    deadline. Every item issued to someone becomes a line; its holder
--    answers "I still have and use it", "I no longer have it" or "I have it,
--    but something is wrong" (a note for the last two). Missing or wrong
--    lines are flagged to whoever started the check, who follows them up.
--    Reminders 3 days before the deadline and on the day; after it, the
--    starter hears how many are still unanswered (run_equipment_check_clocks,
--    called with each notification delivery).
--  * Warranty: purchase date and warranty end on the item, and scans
--    (images or PDFs, 2 MB each) in the private asset-files bucket.

begin;

-- --------------------------------------------------------------- the role
insert into public.preset_capabilities (preset_id, capability_key)
select p.id, c.key
  from public.permission_presets p
 cross join (values ('it.view'), ('it.assign')) as c(key)
 where p.name = 'General Administrator' and p.company_id is null
on conflict do nothing;

insert into public.grant_capabilities (grant_id, capability_key)
select g.id, pc.capability_key
  from public.access_grants g
  join public.permission_presets p on p.id = g.source_preset_id and p.name = 'General Administrator' and p.company_id is null
  join public.preset_capabilities pc on pc.preset_id = p.id
on conflict do nothing;

update public.permission_presets
   set description = 'Administration, hiring approvals, equipment and onboarding: approves hiring requests and offers, confirms hires, runs the equipment check, the new-hire checklist, company access and connections'
 where name = 'General Administrator' and company_id is null;

-- ------------------------------------------------------- the equipment check
create table public.equipment_checks (
  id uuid primary key default gen_random_uuid(),
  company_id uuid not null references public.companies(id),
  name text not null check (length(trim(name)) between 3 and 120),
  deadline date not null,
  status text not null default 'open' check (status in ('open', 'closed')),
  started_by uuid references public.people(id),
  started_at timestamptz not null default now(),
  closed_by uuid references public.people(id),
  closed_at timestamptz
);
create unique index one_open_equipment_check on public.equipment_checks (company_id) where status = 'open';

create table public.equipment_check_items (
  id uuid primary key default gen_random_uuid(),
  check_id uuid not null references public.equipment_checks(id) on delete cascade,
  company_id uuid not null references public.companies(id),
  asset_id uuid not null references public.assets(id) on delete cascade,
  person_id uuid not null references public.people(id) on delete cascade,
  answer text check (answer in ('have', 'missing', 'issue')),
  note text check (note is null or length(note) <= 500),
  answered_at timestamptz,
  followed_up_at timestamptz,
  followed_up_by uuid references public.people(id),
  follow_up_note text check (follow_up_note is null or length(follow_up_note) <= 500),
  unique (check_id, asset_id)
);
create index equipment_check_items_person on public.equipment_check_items (person_id) where answer is null;

alter table public.equipment_checks enable row level security;
alter table public.equipment_check_items enable row level security;

create policy sel on public.equipment_checks for select
  using (app.can_see_asset(company_id)
         or exists (select 1 from public.equipment_check_items i where i.check_id = equipment_checks.id and i.person_id = app.current_person_id()));
create policy sel on public.equipment_check_items for select
  using (person_id = app.current_person_id() or app.can_see_asset(company_id));
-- Writes go through the functions below only.

grant select on public.equipment_checks, public.equipment_check_items to authenticated;
grant all on public.equipment_checks, public.equipment_check_items to service_role;

/** Start the check for one company: every issued item becomes a line, and each holder is told. */
create or replace function public.start_equipment_check(p_company_id uuid, p_deadline date, p_name text default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_me uuid := app.current_person_id();
  v_check uuid;
  v_name text := coalesce(nullif(trim(p_name), ''), 'Equipment check ' || to_char(current_date, 'YYYY'));
  v_lines int;
  v_people int := 0;
  v_to uuid;
  v_count int;
begin
  if v_me is null then raise exception 'Sign in to continue.' using errcode = '42501'; end if;
  if not app.can_work_asset(p_company_id, 'it.assign') then
    raise exception 'You need to manage equipment in this company.' using errcode = '42501';
  end if;
  if p_deadline is null or p_deadline < current_date then
    raise exception 'Pick a deadline from today on.' using errcode = '22023';
  end if;
  if exists (select 1 from public.equipment_checks where company_id = p_company_id and status = 'open') then
    raise exception 'This company already has an open equipment check. Close it first.' using errcode = '22023';
  end if;

  insert into public.equipment_checks (company_id, name, deadline, started_by)
  values (p_company_id, v_name, p_deadline, v_me) returning id into v_check;

  insert into public.equipment_check_items (check_id, company_id, asset_id, person_id)
  select v_check, p_company_id, a.id, aa.person_id
    from public.assets a
    join public.asset_assignments aa on aa.asset_id = a.id and aa.returned_at is null and aa.issued_at is not null
   where a.company_id = p_company_id
  on conflict (check_id, asset_id) do nothing;
  get diagnostics v_lines = row_count;

  for v_to, v_count in
    select person_id, count(*) from public.equipment_check_items where check_id = v_check group by person_id
  loop
    v_people := v_people + 1;
    perform app.notify(v_to, p_company_id, 'equipment.check',
      v_name || ': confirm your equipment',
      v_count || ' item' || case when v_count = 1 then '' else 's' end || ' to confirm by ' || to_char(p_deadline, 'DD Mon YYYY')
        || ' · My workspace → Equipment check',
      '/me', 'equipment_check', v_check, 'equipment.check:' || v_check || ':' || v_to, false);
  end loop;

  return jsonb_build_object('check_id', v_check, 'lines', v_lines, 'people', v_people);
end $$;

/** The holder answers for one item. */
create or replace function public.answer_equipment_check(p_item_id uuid, p_answer text, p_note text default null)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_me uuid := app.current_person_id();
  v_item public.equipment_check_items;
  v_check public.equipment_checks;
  v_note text := nullif(trim(coalesce(p_note, '')), '');
  v_who text;
  v_tag text;
begin
  if v_me is null then raise exception 'Sign in to continue.' using errcode = '42501'; end if;
  select * into v_item from public.equipment_check_items where id = p_item_id for update;
  if not found or v_item.person_id <> v_me then
    raise exception 'That item is not on your equipment check.' using errcode = '42501';
  end if;
  select * into v_check from public.equipment_checks where id = v_item.check_id;
  if v_check.status <> 'open' then
    raise exception 'This equipment check is closed.' using errcode = '22023';
  end if;
  if p_answer not in ('have', 'missing', 'issue') then
    raise exception 'Pick one of the three answers.' using errcode = '22023';
  end if;
  if p_answer <> 'have' and length(coalesce(v_note, '')) < 3 then
    raise exception 'Say what happened, in a few words.' using errcode = '22023';
  end if;
  if length(coalesce(v_note, '')) > 500 then
    raise exception 'Keep the note under 500 characters.' using errcode = '22023';
  end if;

  update public.equipment_check_items
     set answer = p_answer, note = v_note, answered_at = now(), followed_up_at = null, followed_up_by = null, follow_up_note = null
   where id = p_item_id;

  if p_answer <> 'have' and v_check.started_by is not null and v_check.started_by <> v_me then
    select full_name into v_who from public.people where id = v_me;
    select coalesce(nullif(asset_tag, ''), model, 'an item') into v_tag from public.assets where id = v_item.asset_id;
    perform app.notify(v_check.started_by, v_check.company_id, 'equipment.check_flag',
      coalesce(v_who, 'Someone') || case when p_answer = 'missing' then ' no longer has ' else ' reports a problem with ' end || v_tag,
      v_check.name || ' · ' || v_note,
      '/equipment/' || v_item.asset_id, 'asset', v_item.asset_id,
      'equipment.check_flag:' || p_item_id || ':' || p_answer || ':' || to_char(now(), 'YYYYMMDDHH24MISS'), false);
  end if;
  return jsonb_build_object('item_id', p_item_id, 'answer', p_answer);
end $$;

/** The equipment person records how a missing or wrong line was settled. */
create or replace function public.follow_up_equipment_check(p_item_id uuid, p_note text)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_me uuid := app.current_person_id();
  v_item public.equipment_check_items;
  v_note text := nullif(trim(coalesce(p_note, '')), '');
begin
  if v_me is null then raise exception 'Sign in to continue.' using errcode = '42501'; end if;
  select * into v_item from public.equipment_check_items where id = p_item_id for update;
  if not found then raise exception 'That line no longer exists.' using errcode = '22023'; end if;
  if not app.can_work_asset(v_item.company_id, 'it.assign') then
    raise exception 'You need to manage equipment in this company.' using errcode = '42501';
  end if;
  if v_item.answer not in ('missing', 'issue') then
    raise exception 'Only a missing or wrong item is followed up.' using errcode = '22023';
  end if;
  if length(coalesce(v_note, '')) < 3 or length(v_note) > 500 then
    raise exception 'Say how it was settled, in a few words.' using errcode = '22023';
  end if;
  update public.equipment_check_items
     set followed_up_at = now(), followed_up_by = v_me, follow_up_note = v_note
   where id = p_item_id;
  return jsonb_build_object('item_id', p_item_id);
end $$;

/** Close the check; unanswered lines stay as they are, for the record. */
create or replace function public.close_equipment_check(p_check_id uuid)
returns jsonb language plpgsql security definer set search_path = ''
as $$
declare
  v_me uuid := app.current_person_id();
  v_check public.equipment_checks;
  v_open int;
begin
  if v_me is null then raise exception 'Sign in to continue.' using errcode = '42501'; end if;
  select * into v_check from public.equipment_checks where id = p_check_id for update;
  if not found then raise exception 'That equipment check no longer exists.' using errcode = '22023'; end if;
  if not app.can_work_asset(v_check.company_id, 'it.assign') then
    raise exception 'You need to manage equipment in this company.' using errcode = '42501';
  end if;
  if v_check.status = 'closed' then raise exception 'This equipment check is already closed.' using errcode = '22023'; end if;
  update public.equipment_checks set status = 'closed', closed_by = v_me, closed_at = now() where id = p_check_id;
  select count(*) into v_open from public.equipment_check_items where check_id = p_check_id and answer is null;
  return jsonb_build_object('check_id', p_check_id, 'unanswered', v_open);
end $$;

/** Reminders and the overdue notice; the server runs it with each notification delivery. */
create or replace function public.run_equipment_check_clocks()
returns int language plpgsql security definer set search_path = ''
as $$
declare
  r record;
  v_n int := 0;
begin
  for r in
    select c.id, c.company_id, c.name, c.deadline, i.person_id, count(*) as open_items
      from public.equipment_checks c
      join public.equipment_check_items i on i.check_id = c.id and i.answer is null
     where c.status = 'open' and current_date >= c.deadline - 3 and current_date <= c.deadline
     group by c.id, c.company_id, c.name, c.deadline, i.person_id
  loop
    perform app.notify(r.person_id, r.company_id, 'equipment.check_reminder',
      r.name || ': ' || case when current_date = r.deadline then 'last day to confirm' else 'confirm your equipment' end,
      r.open_items || ' item' || case when r.open_items = 1 then '' else 's' end || ' still to confirm by ' || to_char(r.deadline, 'DD Mon YYYY'),
      '/me', 'equipment_check', r.id,
      'equipment.check_reminder:' || r.id || ':' || r.person_id || ':' || case when current_date = r.deadline then 'due' else 'soon' end, false);
    v_n := v_n + 1;
  end loop;

  for r in
    select c.id, c.company_id, c.name, c.started_by, count(i.id) filter (where i.answer is null) as open_items
      from public.equipment_checks c
      join public.equipment_check_items i on i.check_id = c.id
     where c.status = 'open' and current_date > c.deadline and c.started_by is not null
     group by c.id, c.company_id, c.name, c.started_by
    having count(i.id) filter (where i.answer is null) > 0
  loop
    perform app.notify(r.started_by, r.company_id, 'equipment.check_overdue',
      r.name || ': ' || r.open_items || ' item' || case when r.open_items = 1 then '' else 's' end || ' not confirmed',
      'The deadline has passed. Open Equipment → Equipment check to follow up or close it.',
      '/equipment', 'equipment_check', r.id, 'equipment.check_overdue:' || r.id, false);
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

revoke all on function public.start_equipment_check(uuid, date, text) from public;
revoke all on function public.answer_equipment_check(uuid, text, text) from public;
revoke all on function public.follow_up_equipment_check(uuid, text) from public;
revoke all on function public.close_equipment_check(uuid) from public;
revoke all on function public.run_equipment_check_clocks() from public;
grant execute on function public.start_equipment_check(uuid, date, text) to authenticated, service_role;
grant execute on function public.answer_equipment_check(uuid, text, text) to authenticated, service_role;
grant execute on function public.follow_up_equipment_check(uuid, text) to authenticated, service_role;
grant execute on function public.close_equipment_check(uuid) to authenticated, service_role;
grant execute on function public.run_equipment_check_clocks() to service_role;

-- ---------------------------------------------------------------- warranty
alter table public.assets
  add column if not exists purchase_date date,
  add column if not exists warranty_until date;

create table public.asset_files (
  id uuid primary key default gen_random_uuid(),
  asset_id uuid not null references public.assets(id) on delete cascade,
  company_id uuid not null references public.companies(id),
  storage_path text not null unique,
  original_name text not null check (length(original_name) <= 200),
  mime_type text not null check (mime_type in ('image/jpeg', 'image/png', 'image/webp', 'application/pdf')),
  size_bytes int not null check (size_bytes > 0 and size_bytes <= 2097152),
  uploaded_by uuid references public.people(id),
  created_at timestamptz not null default now()
);
create index asset_files_asset on public.asset_files (asset_id);
alter table public.asset_files enable row level security;
create policy sel on public.asset_files for select using (app.can_see_asset(company_id));
create policy ins on public.asset_files for insert with check (app.can_work_asset(company_id, 'it.assign'));
create policy del on public.asset_files for delete using (app.can_work_asset(company_id, 'it.assign'));
grant select, insert, delete on public.asset_files to authenticated;
grant all on public.asset_files to service_role;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('asset-files', 'asset-files', false, 2097152, array['image/jpeg', 'image/png', 'image/webp', 'application/pdf'])
on conflict (id) do update set file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

create policy "asset files: equipment staff read" on storage.objects for select
  using (bucket_id = 'asset-files' and app.can_see_asset(app.document_object_company(name)));
create policy "asset files: equipment staff upload" on storage.objects for insert
  with check (bucket_id = 'asset-files' and app.document_object_company(name) is not null
              and app.can_work_asset(app.document_object_company(name), 'it.assign'));
create policy "asset files: equipment staff delete" on storage.objects for delete
  using (bucket_id = 'asset-files' and app.document_object_company(name) is not null
         and app.can_work_asset(app.document_object_company(name), 'it.assign'));

commit;
