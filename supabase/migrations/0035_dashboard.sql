-- 0035_dashboard.sql
-- The Home the stakeholders saw on the prototype (plan 044), on real data
-- and gated by what the viewer may see:
--   * kudos — a colleague thanks a colleague; the wall is read by everyone
--     who shares a company with the receiver; the giver (or an admin) removes;
--   * dashboard_snapshot(p_days) — one call for the team facts the page
--     needs: headcount, colleagues, birthdays (day and month only — the
--     year never leaves the database), work anniversaries, new teammates,
--     the kudos wall with names, the last payroll per company for
--     payroll.summary holders.
-- "Colleagues" are the people employed in the companies the viewer belongs
-- to (app.in_company: employed there, or holding a grant there; admins see
-- the whole holding).

-- Sharing a company with someone (or being them).
create or replace function app.is_colleague(p uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select app.is_self(p) or exists (
    select 1 from public.employment_periods ep
    join public.employment_statuses es on es.key = ep.status
    where ep.person_id = p and es.counts_as_employed and app.in_company(ep.company_id))
$$;

-- Days from today to the next yearly occurrence of a date's day and month.
-- Adding whole years to 29 Feb lands on 28 Feb in common years.
create or replace function app.days_until_next(p date) returns int
language sql stable set search_path = public as $$
  select case when this_year >= current_date then this_year - current_date else next_year - current_date end
  from (select (p + make_interval(years => extract(year from current_date)::int - extract(year from p)::int))::date as this_year,
               (p + make_interval(years => extract(year from current_date)::int - extract(year from p)::int + 1))::date as next_year) x
$$;

create table public.kudos (
  id uuid primary key default gen_random_uuid(),
  from_person_id uuid not null references public.people(id),
  to_person_id uuid not null references public.people(id),
  message text not null check (length(btrim(message)) between 1 and 280),
  created_at timestamptz not null default now(),
  check (from_person_id <> to_person_id)
);
create index kudos_created_idx on public.kudos (created_at desc);
create index kudos_to_idx on public.kudos (to_person_id);
alter table public.kudos enable row level security;
create policy sel on public.kudos for select to authenticated
  using (app.is_self(from_person_id) or app.is_colleague(to_person_id));
create policy ins on public.kudos for insert to authenticated
  with check (app.is_self(from_person_id) and app.is_colleague(to_person_id));
create policy del on public.kudos for delete to authenticated
  using (app.is_self(from_person_id) or app.is_admin());
grant select, insert, delete on public.kudos to authenticated;
grant all on public.kudos to service_role;
create trigger audit after insert or update or delete on public.kudos
  for each row execute function app.audit();

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
    select c.id, c.name from public.companies c
    where c.archived_at is null and app.in_company(c.id)
  ),
  team as (
    -- one row per person: their current employment in a company I belong to
    select distinct on (p.id)
           p.id, p.full_name, ep.job_title, ep.status, ep.start_date, mc.id as company_id, mc.name as company_name
    from public.people p
    join public.employment_periods ep on ep.person_id = p.id
    join public.employment_statuses es on es.key = ep.status and es.counts_as_employed
    join my_companies mc on mc.id = ep.company_id
    where p.archived_at is null
    order by p.id, ep.start_date desc
  ),
  wall as (
    select k.id, k.message, k.created_at, k.from_person_id, k.to_person_id,
           pf.full_name as from_name, pt.full_name as to_name, (k.from_person_id = me) as mine
    from public.kudos k
    join public.people pf on pf.id = k.from_person_id
    join public.people pt on pt.id = k.to_person_id
    where k.from_person_id = me or exists (select 1 from team t where t.id = k.to_person_id)
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
                  where pd.birth_date is not null and app.days_until_next(pd.birth_date) <= v_days),
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
                'from_name', from_name, 'to_name', to_name, 'mine', mine) order by created_at desc), '[]'::jsonb)
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
                  select distinct on (mc.id) mc.name, pp.period_start, pp.period_end, pp.currency, pp.status,
                         (select coalesce(sum(l.amount), 0) from public.payroll_lines l where l.period_id = pp.id) as total,
                         (select count(*) from public.payroll_lines l where l.period_id = pp.id) as people
                  from my_companies mc
                  join public.payroll_periods pp on pp.company_id = mc.id and pp.status in ('approved', 'exported')
                  where app.has_capability(mc.id, 'payroll.summary')
                  order by mc.id, pp.period_end desc, pp.currency
                ) x)
  ) into v;
  return v;
end $$;
grant execute on function public.dashboard_snapshot(int) to authenticated;
