-- 0036_dashboard_scope.sql
-- Limit the dashboard to what the viewer may already see (plan 044, second
-- pass). 0035 scoped the team facts by company membership, which was wider
-- than the rest of the product: the directory gates people by `people.view`
-- and private details by `personal.view`. Now the dashboard follows the same
-- capabilities, so it can never show more than the pages it links to:
--   * the team (headcount, colleagues, anniversaries, newcomers, the biggest
--     team, the fun corner's numbers) → `people.view` in that company;
--   * birthdays (day and month only, as before) → `personal.view`;
--   * payroll → `payroll.summary`, as before;
--   * kudos → `app.can_view_person`, the directory's own rule; a person
--     always reads what they gave or received, so nothing is lost to the
--     recipient.
-- `app.is_colleague` (0035) is replaced by `app.can_view_person` and dropped.

drop policy if exists sel on public.kudos;
drop policy if exists ins on public.kudos;
create policy sel on public.kudos for select to authenticated
  using (app.is_self(from_person_id) or app.is_self(to_person_id) or app.can_view_person(to_person_id));
create policy ins on public.kudos for insert to authenticated
  with check (app.is_self(from_person_id) and app.can_view_person(to_person_id));

drop function if exists app.is_colleague(uuid);

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
    select k.id, k.message, k.created_at, k.from_person_id, k.to_person_id,
           pf.full_name as from_name, pt.full_name as to_name, (k.from_person_id = me) as mine
    from public.kudos k
    join public.people pf on pf.id = k.from_person_id
    join public.people pt on pt.id = k.to_person_id
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
