-- 0073_activity_choices.sql
-- Reading the audit trail (plan 059).
--
-- The Activity tab loads the most recent 200 rows and filters those in the
-- page. That worked until the Zoho import wrote 12,302 rows in a single day:
-- the 200 most recent are now all import, so choosing an entity or searching
-- for a colleague searches inside the import and finds nothing. Ivana's 55
-- real changes sit behind Naum's 12,902 imported ones, invisible.
--
-- The app's filters move into the query to fix that, and a query filter needs
-- something to offer: the people who have actually acted here, and the kinds
-- of thing they touched. Neither can be built from a window of recent rows —
-- that window is the import — so this answers both from the whole trail.
--
-- SECURITY INVOKER on purpose (the default, stated here because it carries the
-- argument): the two select policies on activity_log — 0006's admin /
-- access.manage rule and 0012's recruitment rule — then apply to this query
-- exactly as they apply to the panel's own. A definer function would have to
-- restate those rules, and a restated rule is one that drifts.
--
-- `people` is joined the same way, so a caller who may not see a person still
-- gets their id and a null name; the app has always shown "someone" there.
create or replace function public.activity_choices(
  p_company_id uuid,
  p_holding_wide boolean default false
) returns jsonb
language sql stable set search_path = public as $$
  with visible as (
    select a.actor_person_id, a.entity_type
      from public.activity_log a
     where a.company_id = p_company_id
        -- The holding's own page also answers for what belongs to no single
        -- company: candidates and their files are holding-wide (0067), and
        -- that is where most of the trail lives.
        or (coalesce(p_holding_wide, false) and a.company_id is null)
  ),
  actors as (
    select distinct v.actor_person_id as id, p.full_name
      from visible v
      left join public.people p on p.id = v.actor_person_id
     where v.actor_person_id is not null
  ),
  kinds as (
    select distinct v.entity_type from visible v
  )
  select jsonb_build_object(
    'actors', coalesce((select jsonb_agg(jsonb_build_object('id', a.id, 'full_name', a.full_name)
                                         order by a.full_name nulls last, a.id)
                          from actors a), '[]'::jsonb),
    'entity_types', coalesce((select jsonb_agg(k.entity_type order by k.entity_type) from kinds k), '[]'::jsonb)
  )
$$;

revoke all on function public.activity_choices(uuid, boolean) from public, anon;
grant execute on function public.activity_choices(uuid, boolean) to authenticated;
