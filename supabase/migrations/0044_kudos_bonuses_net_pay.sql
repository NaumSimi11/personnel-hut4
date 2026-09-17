-- 0044_kudos_bonuses_net_pay.sql
-- Plan 051, the last slice of plan 045: the prototype's Admin tab and its
-- payroll extras, on the real model.
--   1. kudos values — holding-wide, seeded with five, retired never deleted;
--      a kudos may carry one; HR records a kudos on a colleague's behalf
--      with a date, edits and removes what it may manage (people.view where
--      the receiver is employed — never just being the receiver).
--   2. bonuses — payroll_items pending until a prepared period in their
--      currency has a line for the person; reopening releases them.
--   3. net pay, the prototype's estimate — a tax percentage and a flat
--      deduction per company (Settings → Payroll), applied to the recorded
--      amount plus the bonus; statutory contributions stay the accountant's.

-- ------------------------------------------------------------ 1. kudos values
create table public.kudos_values (
  id uuid primary key default gen_random_uuid(),
  name text not null check (length(btrim(name)) between 1 and 60),
  description text check (description is null or length(description) <= 300),
  active boolean not null default true,
  sort_order int not null default 100,
  created_at timestamptz not null default now()
);
create unique index kudos_values_name_key on public.kudos_values (lower(btrim(name)));
alter table public.kudos_values enable row level security;
create policy sel on public.kudos_values for select to authenticated using (true);
grant select on public.kudos_values to authenticated;
grant all on public.kudos_values to service_role;
create trigger audit after insert or update or delete on public.kudos_values
  for each row execute function app.audit();

insert into public.kudos_values (name, description, sort_order) values
  ('Teamwork', 'Went out of their way to help a teammate or another team.', 10),
  ('Ownership', 'Took initiative and saw something through without being asked.', 20),
  ('Customer focus', 'Made things noticeably better for a customer or client.', 30),
  ('Innovation', 'Found a smarter or more efficient way to do something.', 40),
  ('Integrity', 'Did the right thing, especially when it was the harder choice.', 50)
on conflict do nothing;

alter table public.kudos
  add column value_id uuid references public.kudos_values(id) on delete set null,
  add column posted_by uuid references public.people(id);

-- A new kudos may only carry an active value; an existing one keeps its
-- tag when the value is retired (history).
create or replace function app.kudos_value_check() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.value_id is not null
     and (tg_op = 'INSERT' or new.value_id is distinct from old.value_id)
     and not exists (select 1 from public.kudos_values v where v.id = new.value_id and v.active) then
    raise exception 'That kudos value is retired; pick an active one.';
  end if;
  return new;
end $$;
create trigger t1_value_check before insert or update on public.kudos
  for each row execute function app.kudos_value_check();

-- Managing a kudos: admin, or people.view where the receiver is employed.
-- Being the receiver is not enough — that would let anyone polish their wall.
create or replace function app.can_manage_kudos(p_to uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select app.is_admin() or exists (
    select 1 from public.employment_periods ep
    where ep.person_id = p_to and app.has_capability(ep.company_id, 'people.view'))
$$;

drop policy if exists del on public.kudos;
create policy del on public.kudos for delete to authenticated
  using (app.is_self(from_person_id) or app.can_manage_kudos(to_person_id));
-- The wall inserts the four columns a person may set; who recorded it and
-- when are the functions' to write (record_kudos / update_kudos).
revoke insert on public.kudos from authenticated;
grant insert (from_person_id, to_person_id, message, value_id) on public.kudos to authenticated;

/** Admin: add, edit or retire a value. p: {name, description, active}. */
create or replace function public.save_kudos_value(p_id uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_name text := left(btrim(coalesce(p ->> 'name', '')), 60);
  v_desc text := nullif(left(btrim(coalesce(p ->> 'description', '')), 300), '');
  v_active boolean := coalesce((p ->> 'active')::boolean, true);
  v_id uuid := p_id;
begin
  if not app.is_admin() then
    raise exception 'Only an admin shapes the kudos values.' using errcode = '42501';
  end if;
  if v_name = '' then
    raise exception 'Give the value a name.';
  end if;
  if v_id is null then
    insert into public.kudos_values (name, description, active, sort_order)
      values (v_name, v_desc, v_active, coalesce((select max(sort_order) from public.kudos_values), 0) + 10)
      returning id into v_id;
  else
    update public.kudos_values set name = v_name, description = v_desc, active = v_active where id = v_id;
    if not found then
      raise exception 'Kudos value not found.';
    end if;
  end if;
  return jsonb_build_object('id', v_id, 'name', v_name, 'active', v_active);
exception when unique_violation then
  raise exception 'A value called "%" already exists.', v_name;
end $$;
revoke all on function public.save_kudos_value(uuid, jsonb) from public, anon;
grant execute on function public.save_kudos_value(uuid, jsonb) to authenticated, service_role;

-- Shared shape check for record / update: the people, the message, the value, the date.
create or replace function app.kudos_input(p jsonb, p_current public.kudos) returns public.kudos
language plpgsql stable security definer set search_path = public as $$
declare
  k public.kudos := p_current;
  v_date date;
begin
  if p ? 'from_person_id' then k.from_person_id := (p ->> 'from_person_id')::uuid; end if;
  if p ? 'to_person_id' then k.to_person_id := (p ->> 'to_person_id')::uuid; end if;
  if p ? 'message' then k.message := btrim(coalesce(p ->> 'message', '')); end if;
  if p ? 'value_id' then k.value_id := nullif(p ->> 'value_id', '')::uuid; end if;
  if nullif(p ->> 'on_date', '') is not null then
    begin
      v_date := (p ->> 'on_date')::date;
    exception when others then
      raise exception 'The date is not a date.' using errcode = '22023';
    end;
    if v_date > current_date then
      raise exception 'A kudos is not dated in the future.' using errcode = '22023';
    end if;
    -- The same day keeps its clock; today is now; an earlier day sits at noon of that day.
    k.created_at := case when date(k.created_at) = v_date then k.created_at
                         when v_date = current_date then now()
                         else v_date::timestamp + interval '12 hours' end;
  end if;
  if k.from_person_id is null or k.to_person_id is null then
    raise exception 'Say who thanks whom.' using errcode = '22023';
  end if;
  if k.from_person_id = k.to_person_id then
    raise exception 'A kudos goes to someone else.' using errcode = '22023';
  end if;
  if length(k.message) not between 1 and 280 then
    raise exception 'Write the message (up to 280 characters).' using errcode = '22023';
  end if;
  if not exists (select 1 from public.people where id = k.from_person_id and archived_at is null)
     or not exists (select 1 from public.people where id = k.to_person_id and archived_at is null) then
    raise exception 'Person not found.' using errcode = '22023';
  end if;
  return k;
end $$;

/**
 * HR records a kudos on a colleague's behalf: {from_person_id, to_person_id,
 * message, value_id?, on_date?}. Needs management over the receiver and
 * sight of the giver.
 */
create or replace function public.record_kudos(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  k public.kudos;
  v_id uuid;
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  k.created_at := now();
  k := app.kudos_input(p, k);
  if not app.can_manage_kudos(k.to_person_id) then
    raise exception 'Recording a kudos on someone''s behalf needs people.view where the receiver works.' using errcode = '42501';
  end if;
  if not (app.can_view_person(k.from_person_id) or app.can_manage_kudos(k.from_person_id)) then
    raise exception 'You may only name a giver whose record you may see.' using errcode = '42501';
  end if;
  insert into public.kudos (from_person_id, to_person_id, message, value_id, created_at, posted_by)
    values (k.from_person_id, k.to_person_id, k.message, k.value_id, k.created_at, case when k.from_person_id = v_me then null else v_me end)
    returning id into v_id;
  return jsonb_build_object('id', v_id);
end $$;
revoke all on function public.record_kudos(jsonb) from public, anon;
grant execute on function public.record_kudos(jsonb) to authenticated, service_role;

/** Edit a kudos one may manage; the same keys as record_kudos, all optional. */
create or replace function public.update_kudos(p_id uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  k public.kudos;
  v_old_from uuid;
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  select * into k from public.kudos where id = p_id for update;
  if not found then
    raise exception 'Kudos not found.';
  end if;
  if not app.can_manage_kudos(k.to_person_id) then
    raise exception 'Editing a kudos needs people.view where the receiver works.' using errcode = '42501';
  end if;
  v_old_from := k.from_person_id;
  k := app.kudos_input(p, k);
  if not app.can_manage_kudos(k.to_person_id) then
    raise exception 'You may only move a kudos to someone whose kudos you manage.' using errcode = '42501';
  end if;
  if not (app.can_view_person(k.from_person_id) or app.can_manage_kudos(k.from_person_id)) then
    raise exception 'You may only name a giver whose record you may see.' using errcode = '42501';
  end if;
  update public.kudos
     set from_person_id = k.from_person_id, to_person_id = k.to_person_id, message = k.message,
         value_id = k.value_id, created_at = k.created_at,
         -- who recorded it changes only when the giver does: a kudos the giver
         -- posted themselves stays theirs after HR fixes a typo
         posted_by = case when k.from_person_id is distinct from v_old_from
                          then (case when k.from_person_id = v_me then null else v_me end)
                          else posted_by end
   where id = p_id;
  return jsonb_build_object('id', p_id);
end $$;
revoke all on function public.update_kudos(uuid, jsonb) from public, anon;
grant execute on function public.update_kudos(uuid, jsonb) to authenticated, service_role;

/**
 * The Kudos page: the rows the viewer manages (admin: all), newest first,
 * with the months (and counts) they span, and the counts per value for the
 * month asked for ('YYYY-MM', or null for all).
 */
create or replace function public.kudos_overview(p_month text default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v jsonb;
begin
  if app.current_person_id() is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  if p_month is not null and p_month !~ '^\d{4}-\d{2}$' then
    raise exception 'The month is YYYY-MM.' using errcode = '22023';
  end if;
  with managed as (
    select k.id, k.message, k.created_at, k.from_person_id, k.to_person_id, k.value_id, k.posted_by,
           pf.full_name as from_name, pt.full_name as to_name, v.name as value_name, pp.full_name as posted_by_name,
           to_char(k.created_at, 'YYYY-MM') as month
    from public.kudos k
    join public.people pf on pf.id = k.from_person_id
    join public.people pt on pt.id = k.to_person_id
    left join public.kudos_values v on v.id = k.value_id
    left join public.people pp on pp.id = k.posted_by
    where app.can_manage_kudos(k.to_person_id)
  ),
  shown as (select * from managed where p_month is null or month = p_month)
  select jsonb_build_object(
    'rows', (select coalesce(jsonb_agg(jsonb_build_object(
               'id', id, 'message', message, 'created_at', created_at, 'from_person_id', from_person_id, 'to_person_id', to_person_id,
               'from_name', from_name, 'to_name', to_name, 'value_id', value_id, 'value_name', value_name,
               'posted_by_name', posted_by_name) order by created_at desc), '[]'::jsonb) from shown),
    'months', (select coalesce(jsonb_agg(jsonb_build_object('month', month, 'count', n) order by month desc), '[]'::jsonb)
               from (select month, count(*) as n from managed group by month) m),
    'total', (select count(*) from managed),
    'values', (select coalesce(jsonb_agg(jsonb_build_object('id', kv.id, 'name', kv.name, 'description', kv.description, 'active', kv.active,
                 'count', (select count(*) from shown s where s.value_id = kv.id)) order by kv.sort_order, kv.name), '[]'::jsonb)
               from public.kudos_values kv),
    'untagged', (select count(*) from shown where value_id is null))
  into v;
  return v;
end $$;
revoke all on function public.kudos_overview(text) from public, anon;
grant execute on function public.kudos_overview(text) to authenticated, service_role;

-- The Home wall carries the value (0036's body, plus value_id / value_name).
create or replace function public.dashboard_snapshot(p_days int default 30) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  me uuid := app.current_person_id();
  v_days int := least(greatest(coalesce(p_days, 30), 1), 90);
  v jsonb;
begin
  if me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;

  with my_companies as (
    -- the companies whose people I may read
    select c.id, c.name from public.companies c
    where c.archived_at is null and app.has_capability(c.id, 'people.view')
  ),
  team as (
    -- one row per person: their current employment in a company I may read
    select distinct on (p.id)
           p.id, p.full_name, ep.job_title, ep.status, ep.start_date,
           mc.id as company_id, mc.name as company_name
    from public.people p
    join public.employment_periods ep on ep.person_id = p.id
    join public.employment_statuses es on es.key = ep.status and es.counts_as_employed
    join my_companies mc on mc.id = ep.company_id
    where p.archived_at is null
    order by p.id, ep.start_date desc
  ),
  wall as (
    -- mine either way; everyone else's only where I may see the person thanked
    select k.id, k.message, k.created_at, k.from_person_id, k.to_person_id, k.value_id, kv.name as value_name,
           pf.full_name as from_name, pt.full_name as to_name, (k.from_person_id = me) as mine
    from public.kudos k
    join public.people pf on pf.id = k.from_person_id
    join public.people pt on pt.id = k.to_person_id
    left join public.kudos_values kv on kv.id = k.value_id
    where k.from_person_id = me or k.to_person_id = me or app.can_view_person(k.to_person_id)
  )
  select jsonb_build_object(
    'headcount', (select count(*) from team),
    'active', (select count(*) from team where status = 'active'),
    'starting', (select count(*) from team where status = 'pre_start'),
    'colleagues', (select coalesce(jsonb_agg(jsonb_build_object('id', id, 'full_name', full_name, 'company_name', company_name) order by full_name), '[]'::jsonb)
                   from team where id <> me),
    'birthdays', (select coalesce(jsonb_agg(jsonb_build_object(
                    'id', t.id, 'full_name', t.full_name, 'job_title', t.job_title, 'company_name', t.company_name,
                    'on_day', to_char(pd.birth_date, 'DD Mon'), 'in_days', app.days_until_next(pd.birth_date))
                    order by app.days_until_next(pd.birth_date), t.full_name), '[]'::jsonb)
                  from team t
                  join public.person_private_details pd on pd.person_id = t.id
                  -- personal.view over that person, wherever they are employed: person_private_details' own rule,
                  -- not the one employment the team row happens to carry
                  where pd.birth_date is not null
                    and exists (select 1 from public.employment_periods ep2
                                where ep2.person_id = t.id and app.has_capability(ep2.company_id, 'personal.view'))
                    and app.days_until_next(pd.birth_date) <= v_days),
    'anniversaries', (select coalesce(jsonb_agg(jsonb_build_object(
                        'id', a.id, 'full_name', a.full_name, 'job_title', a.job_title, 'company_name', a.company_name,
                        'years', a.years, 'in_days', a.in_days) order by a.in_days, a.full_name), '[]'::jsonb)
                      -- years = the anniversary's year minus the start year (age() would lose one for a 29 Feb start in a common year)
                      from (select t.*, app.days_until_next(t.start_date) as in_days,
                                   (extract(year from current_date + app.days_until_next(t.start_date)) - extract(year from t.start_date))::int as years
                            from team t where t.start_date < current_date) a
                      where a.in_days <= v_days and a.years >= 1),
    'newcomers', (select coalesce(jsonb_agg(jsonb_build_object(
                    'id', id, 'full_name', full_name, 'job_title', job_title, 'company_name', company_name, 'start_date', start_date)
                    order by start_date desc, full_name), '[]'::jsonb)
                  from team where start_date between current_date - v_days and current_date),
    'kudos', (select coalesce(jsonb_agg(jsonb_build_object(
                'id', id, 'message', message, 'created_at', created_at, 'from_person_id', from_person_id, 'to_person_id', to_person_id,
                'from_name', from_name, 'to_name', to_name, 'mine', mine, 'value_id', value_id, 'value_name', value_name) order by created_at desc), '[]'::jsonb)
              from (select * from wall order by created_at desc limit 30) w),
    'top_kudos', (select jsonb_build_object('full_name', to_name, 'count', count(*))
                  from wall group by to_person_id, to_name order by count(*) desc, min(created_at) limit 1),
    'biggest_team', (select jsonb_build_object('name', company_name, 'people', count(*))
                     from team group by company_name order by count(*) desc, company_name limit 1),
    'anniversaries_this_year', (select count(*) from team where start_date < date_trunc('year', current_date)::date),
    'payroll', (select coalesce(jsonb_agg(jsonb_build_object(
                  'company_name', x.name, 'period_start', x.period_start, 'period_end', x.period_end,
                  'currency', x.currency, 'total', x.total, 'people', x.people, 'status', x.status) order by x.period_end desc, x.name), '[]'::jsonb)
                from (
                  -- its own company set: payroll.summary does not imply people.view
                  select distinct on (c.id) c.name, pp.period_start, pp.period_end, pp.currency, pp.status,
                         (select coalesce(sum(l.amount), 0) from public.payroll_lines l where l.period_id = pp.id) as total,
                         (select count(*) from public.payroll_lines l where l.period_id = pp.id) as people
                  from public.companies c
                  join public.payroll_periods pp on pp.company_id = c.id and pp.status in ('approved', 'exported')
                  where c.archived_at is null and app.has_capability(c.id, 'payroll.summary')
                  order by c.id, pp.period_end desc, pp.currency
                ) x)
  ) into v;
  return v;
end $$;

-- ---------------------------------------------------------------- 2. bonuses
create table public.payroll_items (
  id uuid primary key default gen_random_uuid(),
  person_id uuid not null references public.people(id),
  company_id uuid not null references public.companies(id),
  amount numeric(14,2) not null check (amount > 0),
  currency char(3) not null,
  reason text not null check (length(btrim(reason)) between 1 and 200),
  item_date date not null default current_date,
  period_id uuid references public.payroll_periods(id) on delete set null,
  created_by uuid references public.people(id),
  created_at timestamptz not null default now()
);
create index payroll_items_pending_idx on public.payroll_items (company_id, currency) where period_id is null;
create index payroll_items_period_idx on public.payroll_items (period_id);
create index payroll_items_person_idx on public.payroll_items (person_id);
alter table public.payroll_items enable row level security;
create policy sel on public.payroll_items for select to authenticated
  using (app.is_self(person_id) or app.has_capability(company_id, 'payroll.individual'));
grant select on public.payroll_items to authenticated;
grant all on public.payroll_items to service_role;
-- Amounts stay out of the audit trail, like the lines.
create trigger audit after insert or update or delete on public.payroll_items
  for each row execute function app.audit_redacted('amount');

/** {person_id, company_id, amount, currency, reason, item_date?} — payroll.individual in the company. */
create or replace function public.add_payroll_item(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_person uuid := (p ->> 'person_id')::uuid;
  v_company uuid := (p ->> 'company_id')::uuid;
  v_amount numeric(14,2);
  v_currency text := upper(btrim(coalesce(p ->> 'currency', '')));
  v_reason text := left(btrim(coalesce(p ->> 'reason', '')), 200);
  v_date date;
  v_id uuid;
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  if v_company is null or not app.has_capability(v_company, 'payroll.individual') then
    raise exception 'Recording a bonus needs payroll.individual in this company.' using errcode = '42501';
  end if;
  begin
    v_amount := (p ->> 'amount')::numeric;
    v_date := coalesce(nullif(p ->> 'item_date', ''), current_date::text)::date;
  exception when others then
    raise exception 'Check the amount and the date.' using errcode = '22023';
  end;
  if v_amount is null or v_amount <= 0 then
    raise exception 'The amount must be above zero.' using errcode = '22023';
  end if;
  if v_currency !~ '^[A-Z]{3}$' then
    raise exception 'Currency must be a three-letter code like EUR or MKD.' using errcode = '22023';
  end if;
  if v_reason = '' then
    raise exception 'Say what the bonus is for.' using errcode = '22023';
  end if;
  if not exists (select 1 from public.employment_periods ep
                 join public.employment_statuses es on es.key = ep.status and es.counts_as_employed
                 where ep.person_id = v_person and ep.company_id = v_company) then
    raise exception 'The person is not employed in this company.' using errcode = '22023';
  end if;
  insert into public.payroll_items (person_id, company_id, amount, currency, reason, item_date, created_by)
    values (v_person, v_company, v_amount, v_currency, v_reason, v_date, v_me)
    returning id into v_id;
  return jsonb_build_object('id', v_id, 'status', 'pending');
end $$;
revoke all on function public.add_payroll_item(jsonb) from public, anon;
grant execute on function public.add_payroll_item(jsonb) to authenticated, service_role;

/** A pending bonus is removed; one already in a period is not. */
create or replace function public.remove_payroll_item(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_item record;
begin
  if app.current_person_id() is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  select * into v_item from public.payroll_items where id = p_id for update;
  if not found then
    raise exception 'Bonus not found.';
  end if;
  if not app.has_capability(v_item.company_id, 'payroll.individual') then
    raise exception 'Removing a bonus needs payroll.individual in this company.' using errcode = '42501';
  end if;
  if v_item.period_id is not null then
    raise exception 'This bonus is in a prepared period; reopen or prepare the period again first.';
  end if;
  delete from public.payroll_items where id = p_id;
  return jsonb_build_object('removed', true);
end $$;
revoke all on function public.remove_payroll_item(uuid) from public, anon;
grant execute on function public.remove_payroll_item(uuid) to authenticated, service_role;

-- --------------------------------------------------------------- 3. net pay
-- Per company: {tax_rate_percent, deductions_flat} in settings -> 'payroll';
-- the holding's stands in until the company writes its own.
create or replace function app.payroll_settings_for(p_company_id uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select settings -> 'payroll' from public.companies where id = p_company_id
      and jsonb_typeof(settings -> 'payroll') = 'object' and app.jsonb_has_values(settings -> 'payroll')),
    (select settings -> 'payroll' from public.companies where kind = 'holding' and archived_at is null
      and jsonb_typeof(settings -> 'payroll') = 'object' and app.jsonb_has_values(settings -> 'payroll') order by created_at limit 1),
    '{}'::jsonb)
$$;

create or replace function public.payroll_settings(p_company_id uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'tax_rate_percent', coalesce((app.payroll_settings_for(p_company_id) ->> 'tax_rate_percent')::numeric, 0),
    'deductions_flat', coalesce((app.payroll_settings_for(p_company_id) ->> 'deductions_flat')::numeric, 0),
    'own', exists (select 1 from public.companies where id = p_company_id
                   and jsonb_typeof(settings -> 'payroll') = 'object' and app.jsonb_has_values(settings -> 'payroll')))
$$;
revoke all on function public.payroll_settings(uuid) from public, anon;
grant execute on function public.payroll_settings(uuid) to authenticated;

/** {tax_rate_percent 0–100, deductions_flat ≥ 0} — payroll.individual here, or admin. */
create or replace function public.set_payroll_settings(p_company_id uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_rate numeric;
  v_flat numeric;
begin
  if app.current_person_id() is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  if not (app.is_admin() or app.has_capability(p_company_id, 'payroll.individual')) then
    raise exception 'Setting the payroll estimate needs payroll.individual in this company.' using errcode = '42501';
  end if;
  begin
    v_rate := round(coalesce(nullif(p ->> 'tax_rate_percent', ''), '0')::numeric, 2);
    v_flat := round(coalesce(nullif(p ->> 'deductions_flat', ''), '0')::numeric, 2);
  exception when others then
    raise exception 'The tax rate and the deduction are numbers.' using errcode = '22023';
  end;
  if v_rate < 0 or v_rate > 100 then
    raise exception 'The tax rate is a percentage between 0 and 100.' using errcode = '22023';
  end if;
  if v_flat < 0 then
    raise exception 'The deduction is not negative.' using errcode = '22023';
  end if;
  update public.companies
     set settings = settings || jsonb_build_object('payroll', jsonb_build_object('tax_rate_percent', v_rate, 'deductions_flat', v_flat))
   where id = p_company_id;
  if not found then
    raise exception 'Company not found.';
  end if;
  return jsonb_build_object('tax_rate_percent', v_rate, 'deductions_flat', v_flat);
end $$;
revoke all on function public.set_payroll_settings(uuid, jsonb) from public, anon;
grant execute on function public.set_payroll_settings(uuid, jsonb) to authenticated, service_role;

alter table public.payroll_lines
  add column bonus numeric(14,2) not null default 0,
  add column gross numeric(14,2) not null default 0,
  add column tax numeric(14,2) not null default 0,
  add column deductions numeric(14,2) not null default 0,
  add column net numeric(14,2) not null default 0;
-- Existing lines: the estimate on what they carry, with no rate (net = amount).
update public.payroll_lines set gross = amount, net = amount;
-- The new amounts stay out of the audit trail with the old one (0023 redacted amount alone).
drop trigger if exists audit on public.payroll_lines;
create trigger audit after insert or update or delete on public.payroll_lines
  for each row execute function app.audit_redacted('amount,bonus,gross,tax,deductions,net');

alter table public.payroll_periods
  add column tax_rate_percent numeric(5,2),
  add column deductions_flat numeric(14,2),
  add column reopened_at timestamptz;

-- The pinning trigger keeps the new columns too (0023's body plus three lines).
create or replace function app.prepare_payroll_period_row() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.currency := upper(trim(coalesce(new.currency, '')));
  if new.currency !~ '^[A-Z]{3}$' then
    raise exception 'Currency must be a three-letter code like EUR or MKD.';
  end if;
  if tg_op = 'INSERT' then
    new.status := 'draft';
    new.approved_by := null;
    new.exported_at := null;
    new.export_document_id := null;
    new.prepared_by := null;
    new.prepared_at := null;
    new.tax_rate_percent := null;
    new.deductions_flat := null;
    new.reopened_at := null;
  elsif auth.uid() is not null and current_setting('app.payroll_transition', true) is distinct from 'on' then
    if old.status <> 'draft' then
      raise exception 'A period that has been prepared changes only through its workflow.';
    end if;
    new.status := old.status;
    new.approved_by := old.approved_by;
    new.exported_at := old.exported_at;
    new.export_document_id := old.export_document_id;
    new.prepared_by := old.prepared_by;
    new.prepared_at := old.prepared_at;
    new.company_id := old.company_id;
    new.tax_rate_percent := old.tax_rate_percent;
    new.deductions_flat := old.deductions_flat;
    new.reopened_at := old.reopened_at;
  end if;
  new.note := nullif(trim(coalesce(new.note, '')), '');
  return new;
end $$;

-- 0023's prepare, plus: the period's items are released first, the pending
-- bonuses of the currency dated on or before the period end attach where
-- the person has a line, the bonus and the flat deduction sit on the
-- person's first line, the tax on every line's gross.
create or replace function public.prepare_payroll_period(
  p_company_id uuid,
  p_start date,
  p_end date,
  p_currency text,
  p_note text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_currency text := upper(trim(coalesce(p_currency, '')));
  v_period record;
  v_id uuid;
  v_lines int;
  v_uncovered int;
  v_settings jsonb;
  v_rate numeric(5,2);
  v_flat numeric(14,2);
  v_bonuses int;
  v_waiting int;
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  if not app.has_capability(p_company_id, 'payroll.individual') then
    raise exception 'Preparing payroll needs payroll.individual in this company.' using errcode = '42501';
  end if;
  if p_start is null or p_end is null or p_end < p_start then
    raise exception 'Choose the period: the end must not be before the start.';
  end if;
  if v_currency !~ '^[A-Z]{3}$' then
    raise exception 'Currency must be a three-letter code like EUR or MKD.';
  end if;

  select * into v_period from public.payroll_periods
    where company_id = p_company_id and period_start = p_start and period_end = p_end and currency = v_currency
    for update;
  if found then
    if v_period.status not in ('draft', 'in_review') then
      raise exception 'This period is already %; reopen it to prepare it again.', v_period.status;
    end if;
    v_id := v_period.id;
    perform set_config('app.payroll_transition', 'on', true);
    update public.payroll_periods
      set note = coalesce(nullif(trim(coalesce(p_note, '')), ''), note)
      where id = v_id;
    perform set_config('app.payroll_transition', 'off', true);
    delete from public.payroll_lines where period_id = v_id;
  else
    -- Two first-time prepares racing for the same range: the second one
    -- adopts the row the first created.
    insert into public.payroll_periods (company_id, period_start, period_end, currency, note)
      values (p_company_id, p_start, p_end, v_currency, p_note)
      on conflict (company_id, period_start, period_end, currency) do nothing
      returning id into v_id;
    if v_id is null then
      select id into v_id from public.payroll_periods
        where company_id = p_company_id and period_start = p_start and period_end = p_end and currency = v_currency
        for update;
      delete from public.payroll_lines where period_id = v_id;
    end if;
  end if;
  -- Whatever this period had swept goes back to pending before the re-sweep.
  update public.payroll_items set period_id = null where period_id = v_id;

  -- One line per approved record in force at any point of the period, in
  -- the period's currency, for employment that is not former (or ended
  -- inside the period).
  insert into public.payroll_lines
    (period_id, company_id, person_id, employment_period_id, compensation_record_id, full_name, job_title,
     amount, currency, pay_basis_key, effective_from, effective_to, days_covered)
  select v_id, p_company_id, ep.person_id, ep.id, c.id, p.full_name, ep.job_title,
         c.amount, c.currency, c.pay_basis_key,
         greatest(c.effective_date, p_start, ep.start_date) as effective_from,
         least(coalesce(c.end_date, p_end), p_end, coalesce(ep.end_date, p_end)) as effective_to,
         (least(coalesce(c.end_date, p_end), p_end, coalesce(ep.end_date, p_end))
            - greatest(c.effective_date, p_start, ep.start_date) + 1) as days_covered
  from public.compensation_records c
  join public.employment_periods ep on ep.id = c.employment_period_id
  join public.people p on p.id = ep.person_id
  where ep.company_id = p_company_id
    and c.status = 'approved'
    and c.currency = v_currency
    and c.effective_date <= p_end
    and c.effective_date <= coalesce(ep.end_date, p_end)   -- a raise dated after a later-set departure never pays
    and (c.end_date is null or c.end_date >= p_start)
    and ep.start_date <= p_end
    and (ep.end_date is null or ep.end_date >= p_start)
    and ep.status <> 'draft'
  order by p.full_name, c.effective_date;
  get diagnostics v_lines = row_count;

  select count(distinct ep.person_id) into v_uncovered
  from public.employment_periods ep
  where ep.company_id = p_company_id and ep.status = 'active'
    and ep.start_date <= p_end
    and not exists (select 1 from public.payroll_lines l where l.period_id = v_id and l.person_id = ep.person_id);

  -- The bonuses: pending, this company, this currency, dated by the period end, person has a line.
  update public.payroll_items i set period_id = v_id
   where i.company_id = p_company_id and i.period_id is null and i.currency = v_currency and i.item_date <= p_end
     and exists (select 1 from public.payroll_lines l where l.period_id = v_id and l.person_id = i.person_id);
  get diagnostics v_bonuses = row_count;
  select count(*) into v_waiting from public.payroll_items i
   where i.company_id = p_company_id and i.period_id is null and i.currency = v_currency and i.item_date <= p_end;

  -- The estimate: the rate and the flat deduction as they stand now, snapshotted on the period.
  v_settings := app.payroll_settings_for(p_company_id);
  v_rate := coalesce((v_settings ->> 'tax_rate_percent')::numeric, 0);
  v_flat := coalesce((v_settings ->> 'deductions_flat')::numeric, 0);
  with firsts as (
    select distinct on (l.person_id) l.id, l.person_id from public.payroll_lines l
    where l.period_id = v_id order by l.person_id, l.effective_from, l.id
  ),
  bonuses as (select person_id, sum(amount) as bonus from public.payroll_items where period_id = v_id group by person_id)
  update public.payroll_lines l
     set bonus = coalesce(b.bonus, 0), deductions = v_flat
    from firsts f left join bonuses b on b.person_id = f.person_id
   where l.id = f.id;
  update public.payroll_lines
     set gross = amount + bonus,
         tax = round((amount + bonus) * v_rate / 100, 2),
         net = (amount + bonus) - round((amount + bonus) * v_rate / 100, 2) - deductions
   where period_id = v_id;

  perform set_config('app.payroll_transition', 'on', true);
  update public.payroll_periods
    set status = 'in_review', prepared_by = v_me, prepared_at = now(), approved_by = null,
        tax_rate_percent = v_rate, deductions_flat = v_flat, reopened_at = null
    where id = v_id;
  perform set_config('app.payroll_transition', 'off', true);
  return jsonb_build_object('period_id', v_id, 'lines', v_lines, 'uncovered', v_uncovered,
                            'bonuses', v_bonuses, 'bonuses_waiting', v_waiting);
end $$;

-- A reopened period's bonuses are pending again; approving it before it is
-- prepared again would pay lines whose bonuses are also waiting elsewhere.
create or replace function public.approve_payroll_period(p_period_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_period record;
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  select * into v_period from public.payroll_periods where id = p_period_id for update;
  if not found then
    raise exception 'Payroll period not found.';
  end if;
  if not app.has_capability(v_period.company_id, 'payroll.approve') then
    raise exception 'Approving payroll needs payroll.approve in this company.' using errcode = '42501';
  end if;
  if v_period.status <> 'in_review' then
    raise exception 'Only a prepared period can be approved.';
  end if;
  if v_period.reopened_at is not null then
    raise exception 'This period was reopened and its bonuses went back to pending; prepare it again first.';
  end if;
  if v_period.prepared_by is not distinct from v_me then
    raise exception 'The person who prepared a period cannot approve it.' using errcode = '42501';
  end if;
  perform set_config('app.payroll_transition', 'on', true);
  update public.payroll_periods set status = 'approved', approved_by = v_me where id = p_period_id;
  perform set_config('app.payroll_transition', 'off', true);
  return jsonb_build_object('status', 'approved');
end $$;

create or replace function public.reopen_payroll_period(p_period_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_period record;
  v_released int;
begin
  if app.current_person_id() is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  select * into v_period from public.payroll_periods where id = p_period_id for update;
  if not found then
    raise exception 'Payroll period not found.';
  end if;
  if not app.has_capability(v_period.company_id, 'payroll.approve') then
    raise exception 'Reopening payroll needs payroll.approve in this company.' using errcode = '42501';
  end if;
  if v_period.status <> 'approved' then
    raise exception 'Only an approved period can be reopened.';
  end if;
  update public.payroll_items set period_id = null where period_id = p_period_id;
  get diagnostics v_released = row_count;
  -- The lines drop the released bonuses (the period's own rate and deduction
  -- still apply), so the lines and the CSV never carry a bonus that is pending again.
  update public.payroll_lines
     set bonus = 0,
         gross = amount,
         tax = round(amount * coalesce(v_period.tax_rate_percent, 0) / 100, 2),
         net = amount - round(amount * coalesce(v_period.tax_rate_percent, 0) / 100, 2) - deductions
   where period_id = p_period_id and bonus <> 0;
  perform set_config('app.payroll_transition', 'on', true);
  update public.payroll_periods set status = 'in_review', approved_by = null, reopened_at = now() where id = p_period_id;
  perform set_config('app.payroll_transition', 'off', true);
  return jsonb_build_object('status', 'in_review', 'bonuses_released', v_released);
end $$;
