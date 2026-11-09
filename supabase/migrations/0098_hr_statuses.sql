-- 0098_hr_statuses.sql
-- HR's own statuses (2026-11-09): the orange column T ("Status for this
-- job") of HR's Candidate-Job View is the only vocabulary. Every status 0095
-- seeded from Zoho goes; the eighteen keys HR wrote stay, each on the stage
-- most of its rows sit on, with the outcome its name says. The label is the
-- key until HR names it on Hiring → Labels.
--
-- Every application takes the key HR wrote for it, and the stage of that key.
-- The per-row map is not in the database (the import skipped column T), so
-- the caller loads it first into pg_temp.hr_status_map (candidate_display_id,
-- job_display_id, key). An empty pipeline (a fresh local database) needs no
-- map. One transaction: a half-moved pipeline is worse than none.

begin;

-- ----------------------------------------------------------------- guard
do $$
begin
  if exists (select 1 from public.applications) then
    if to_regclass('pg_temp.hr_status_map') is null then
      raise exception '0098 moves every application to HR''s statuses: load pg_temp.hr_status_map first.';
    end if;
  end if;
end $$;

-- The steps-aside the import uses: no audit row, notification or job fill per moved row.
select set_config('app.bulk_import', 'on', true);

-- ------------------------------------------------------------ vocabulary
create temp table hr_statuses (key text primary key, stage_key text, sort_order int, outcome text) on commit drop;
insert into hr_statuses values
  ('sourced',                  'screening', 10, 'open'),
  ('contacted',                'screening', 20, 'open'),
  ('interested',               'screening', 30, 'open'),
  ('no_response',              'screening', 40, 'withdrew'),
  ('not_interested',           'screening', 50, 'withdrew'),
  ('unqualified',              'screening', 60, 'rejected'),
  ('contact_in_future',        'screening', 70, 'withdrew'),
  ('do_not_contact',           'screening', 80, 'withdrew'),
  ('interview_to_schedule',    'interview', 10, 'open'),
  ('interview_hr',             'interview', 20, 'open'),
  ('interview_stakeholders',   'interview', 30, 'open'),
  ('interview_task',           'interview', 40, 'open'),
  ('rejected_by_hr',           'interview', 50, 'rejected'),
  ('rejected_after_interview', 'interview', 60, 'rejected'),
  ('withdrawn',                'interview', 70, 'withdrew'),
  ('offer_made',               'offer',     10, 'open'),
  ('offer_declined',           'offer',     20, 'withdrew'),
  ('hired',                    'hired',     10, 'hired');

-- Old labels step aside first, so a key-as-label never meets an old label at its stage.
update public.application_sub_statuses set label = '~' || key;
insert into public.application_sub_statuses (key, stage_key, label, sort_order, outcome, archived_at)
  select key, stage_key, key, sort_order, outcome, null from hr_statuses
on conflict (key) do update
  set stage_key = excluded.stage_key, label = excluded.label, sort_order = excluded.sort_order,
      outcome = excluded.outcome, archived_at = null;

-- ---------------------------------------------------------- applications
do $$
declare v_missing int; v_bad int; v_moved int;
begin
  if not exists (select 1 from public.applications) then return; end if;

  select count(*) into v_bad from pg_temp.hr_status_map m
   where not exists (select 1 from hr_statuses s where s.key = m.key);
  if v_bad > 0 then
    raise exception '% rows of the map name a key that is not one of HR''s statuses.', v_bad;
  end if;

  select count(*) into v_missing
    from public.applications a
    join public.candidates c on c.id = a.candidate_id
    join public.jobs j on j.id = a.job_id
   where not exists (select 1 from pg_temp.hr_status_map m
                      where m.candidate_display_id = c.custom->'zoho'->>'Candidate ID'
                        and m.job_display_id = j.custom->'zoho'->>'display_id');
  if v_missing > 0 then
    raise exception '% applications have no row in the map.', v_missing;
  end if;

  update public.applications a
     set stage_key = s.stage_key, sub_status_key = m.key
    from public.candidates c, public.jobs j, pg_temp.hr_status_map m, hr_statuses s
   where c.id = a.candidate_id and j.id = a.job_id
     and m.candidate_display_id = c.custom->'zoho'->>'Candidate ID'
     and m.job_display_id = j.custom->'zoho'->>'display_id'
     and s.key = m.key;
  get diagnostics v_moved = row_count;
  if v_moved <> (select count(*) from public.applications) then
    raise exception 'Moved % of % applications.', v_moved, (select count(*) from public.applications);
  end if;
end $$;

-- The history keeps reading: an event naming a status that goes now names
-- the status its application holds (to), or nothing (from).
update public.application_events e
   set to_sub_status_key = a.sub_status_key
  from public.applications a
 where a.id = e.application_id
   and e.to_sub_status_key is not null
   and e.to_sub_status_key not in (select key from hr_statuses);
update public.application_events
   set from_sub_status_key = null
 where from_sub_status_key is not null
   and from_sub_status_key not in (select key from hr_statuses);

delete from public.application_sub_statuses where key not in (select key from hr_statuses);

-- --------------------------------------------------------------- default
-- HR has no "came to us" status: every Screening row starts as sourced.
create or replace function app.default_sub_status(p_stage text, p_source_key text) returns text
language sql stable security definer set search_path = public as $$
  select s.key from public.application_sub_statuses s
   where s.stage_key = p_stage and s.archived_at is null
   order by (s.key = 'sourced') desc, s.sort_order, s.key
   limit 1
$$;

select set_config('app.bulk_import', 'off', true);
commit;
