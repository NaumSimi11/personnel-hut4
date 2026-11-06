-- 0097_hiring_summary_and_import.sql
--
-- Part 1 (egress): the Home page and the Openings panel counted by downloading
-- every application (thousands of rows, paged past PostgREST's 1,000 cap). The
-- database returns the counts instead. Part 2 (the Zoho CSV import function)
-- is appended below by a later task.

begin;

-- ============================================================ Part 1: summaries

-- ---------------------------------------------------------------- hiring_summary
-- What Home's recruitment block draws, counted in the database and limited to
-- the companies where the caller holds candidates.view:
--   by_job         applications on ready/open/on_hold jobs, per job, stage and in_play
--   not_responding applications app.not_responding flags (the report's rule)
--   recent         the five newest applications still in play, on those same live jobs
create or replace function public.hiring_summary() returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_visible uuid[];
  v_by_job jsonb;
  v_not_responding bigint;
  v_recent jsonb;
begin
  if app.current_person_id() is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;

  select coalesce(array_agg(c.id), '{}') into v_visible
    from public.companies c where app.has_capability(c.id, 'candidates.view');

  select coalesce(jsonb_agg(jsonb_build_object(
           'job_id', g.job_id, 'stage_key', g.stage_key, 'in_play', g.in_play,
           'count', g.n, 'last_received_at', g.last_received_at)
         order by g.job_id, g.stage_key, g.in_play desc), '[]'::jsonb) into v_by_job
    from (
      select a.job_id, a.stage_key, a.in_play, count(*) as n, max(a.received_at) as last_received_at
        from public.applications a
        join public.jobs j on j.id = a.job_id
       where a.company_id = any (v_visible)
         and j.status in ('ready', 'open', 'on_hold')
       group by a.job_id, a.stage_key, a.in_play
    ) g;

  select count(*) into v_not_responding
    from public.applications a
   where a.company_id = any (v_visible) and a.in_play and app.not_responding(a);

  select coalesce(jsonb_agg(jsonb_build_object(
           'application_id', r.id, 'candidate_name', r.candidate_name, 'job_title', r.job_title,
           'company_name', r.company_name, 'stage_key', r.stage_key, 'received_at', r.received_at)
         order by r.received_at desc, r.id), '[]'::jsonb) into v_recent
    from (
      select a.id, c.full_name as candidate_name, j.title as job_title, co.name as company_name,
             a.stage_key, a.received_at
        from public.applications a
        join public.candidates c on c.id = a.candidate_id
        join public.jobs j on j.id = a.job_id
        join public.companies co on co.id = a.company_id
       where a.company_id = any (v_visible) and a.in_play
         and j.status in ('ready', 'open', 'on_hold')
       order by a.received_at desc, a.id
       limit 5
    ) r;

  return jsonb_build_object('by_job', v_by_job, 'not_responding', v_not_responding, 'recent', v_recent);
end $$;

-- --------------------------------------------------------------- opening_counts
-- The Openings panel's per-job counts for the jobs it already loaded: still in
-- play, hired, and everything ever received (the rule for deleting a job).
create or replace function public.opening_counts(p_job_ids uuid[])
returns table (job_id uuid, in_play int, hired int, total int)
language plpgsql stable security definer set search_path = public as $$
begin
  if app.current_person_id() is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  return query
    select a.job_id,
           (count(*) filter (where a.in_play))::int,
           (count(*) filter (where a.stage_key = 'hired'))::int,
           count(*)::int
      from public.applications a
     where a.job_id = any (coalesce(p_job_ids, '{}'))
       and a.company_id in (select c.id from public.companies c where app.has_capability(c.id, 'candidates.view'))
     group by a.job_id;
end $$;

revoke all on function public.hiring_summary(), public.opening_counts(uuid[]) from public, anon;
grant execute on function public.hiring_summary() to authenticated;
grant execute on function public.opening_counts(uuid[]) to authenticated;

-- ============================================================ Part 2: import
-- HR's Zoho Recruit "Candidate-Job View" (the payload server/scripts/
-- zoho-job-view-extract.ts writes) loaded in one all-or-nothing call, on the
-- Zoho statuses. The shape and discipline of import_zoho_recruit (0067):
-- pass 1 decides every row; p_commit = false returns the report without
-- writing; p_commit = true writes all or nothing, and any refused row refuses
-- the lot. Zoho's data is the truth: the import never writes to jobs, sends no
-- notification and logs one summary row instead of one per row.

-- ------------------------------------------------------------ the bulk flag
-- While app.bulk_import is 'on' (set local by the import) these four trigger
-- functions step aside. Otherwise they are 0005's audit, 0018's redacted
-- audit, 0096's owner notification and 0096's fill-on-hire, unchanged.
create or replace function app.audit() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  rec jsonb := to_jsonb(coalesce(new, old));
begin
  if current_setting('app.bulk_import', true) = 'on' then
    return coalesce(new, old);
  end if;
  insert into public.activity_log
    (company_id, actor_person_id, actor_user_id, entity_type, entity_id, action, before, after)
  values (
    (rec->>'company_id')::uuid,
    app.current_person_id(),
    auth.uid(),
    tg_table_name,
    rec->>'id',
    tg_op,
    case when tg_op <> 'INSERT' then to_jsonb(old) end,
    case when tg_op <> 'DELETE' then to_jsonb(new) end
  );
  return coalesce(new, old);
end $$;

create or replace function app.audit_redacted() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  rec jsonb := to_jsonb(coalesce(new, old));
  v_keys text[] := string_to_array(coalesce(tg_argv[0], ''), ',');
  v_before jsonb := case when tg_op <> 'INSERT' then to_jsonb(old) - v_keys end;
  v_after jsonb := case when tg_op <> 'DELETE' then to_jsonb(new) - v_keys end;
begin
  if current_setting('app.bulk_import', true) = 'on' then
    return coalesce(new, old);
  end if;
  insert into public.activity_log
    (company_id, actor_person_id, actor_user_id, entity_type, entity_id, action, before, after)
  values (
    (rec->>'company_id')::uuid,
    app.current_person_id(),
    auth.uid(),
    tg_table_name,
    rec->>'id',
    tg_op,
    v_before,
    v_after
  );
  return coalesce(new, old);
end $$;

create or replace function app.notify_application_owner() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_candidate text; v_job text;
begin
  if current_setting('app.bulk_import', true) = 'on' then return new; end if;
  if new.owner_id is null or new.owner_id is not distinct from old.owner_id and new.next_action is not distinct from old.next_action then return new; end if;
  if new.owner_id = app.current_person_id() or not new.in_play then return new; end if;
  select c.full_name, j.title into v_candidate, v_job from public.applications a
    join public.candidates c on c.id = a.candidate_id join public.jobs j on j.id = a.job_id where a.id = new.id;
  perform app.notify(new.owner_id, new.company_id, 'candidate.assigned', 'Candidate assigned to you: ' || coalesce(v_candidate, 'Candidate'),
    coalesce(v_job, 'Role') || ' · ' || coalesce(new.next_action, 'set the next action') || coalesce(' · due ' || to_char(new.next_action_due, 'DD Mon YYYY'), ''),
    '/hiring/applications/' || new.id, 'application', new.id,
    'candidate.assigned:' || new.id || ':' || new.owner_id || ':' || coalesce(new.next_action, ''));
  return new;
end $$;

create or replace function app.applications_fill_job() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if current_setting('app.bulk_import', true) = 'on' then return new; end if;
  if new.stage_key = 'hired' and old.stage_key is distinct from 'hired' then
    update public.jobs j
       set status = 'filled'
     where j.id = new.job_id
       and j.status in ('ready', 'open', 'on_hold')
       and (select count(*) from public.applications a
             where a.job_id = new.job_id and a.stage_key = 'hired') >= app.job_headcount(new.job_id);
    if found then
      perform app.close_in_play(new.job_id, app.current_person_id(), 'Position filled.');
    end if;
  end if;
  return new;
end $$;

-- -------------------------------------------------------------- helpers
-- Whether a payload stamp reads as a timestamp: a bad one is a refused row,
-- never a failed cast halfway through the plan.
create or replace function app.is_timestamptz(p text) returns boolean
language plpgsql stable as $$
begin
  perform p::timestamptz;
  return true;
exception when others then
  return false;
end $$;

-- A payload stamp that is present but unreadable, as a problem list.
create or replace function app.zoho_stamp_problems(p_row jsonb, p_fields text[]) returns text[]
language sql stable as $$
  select coalesce(array_agg(format('%s "%s" is not a timestamp', f, p_row->>f) order by f), '{}')
    from unnest(p_fields) f
   where nullif(p_row->>f, '') is not null and not app.is_timestamptz(p_row->>f)
$$;

-- ------------------------------------------------------------- pass 1: plan
-- Decides every row into four temp tables (dropped at commit): the people
-- matched by name, and the candidates, applications and notes, each with its
-- id, whether it is new, the resolved references and its problems. Writes
-- nothing else.
create or replace function app.zoho_job_view_plan(p_payload jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare v_table text;
begin
  -- A second run in the same transaction (a dry run, then the commit).
  foreach v_table in array array['zoho_jv_people', 'zoho_jv_jobs', 'zoho_jv_cand', 'zoho_jv_app', 'zoho_jv_note'] loop
    if to_regclass('pg_temp.' || v_table) is not null then
      execute format('drop table pg_temp.%I', v_table);
    end if;
  end loop;

  -- Names that point at exactly one person; a shared name matches nobody.
  create temp table zoho_jv_people on commit drop as
    select lower(btrim(full_name)) as name_key, (array_agg(id))[1] as person_id
      from public.people group by 1 having count(*) = 1;

  create temp table zoho_jv_jobs on commit drop as
    select custom->'zoho'->>'display_id' as display_id, count(*) as n,
           (array_agg(id))[1] as job_id, (array_agg(company_id))[1] as company_id
      from public.jobs where custom->'zoho'->>'display_id' is not null group by 1;

  create temp table zoho_jv_cand on commit drop as
  with c as (
    select e.v, e.ord, nullif(btrim(coalesce(e.v->>'zoho_id', '')), '') as ref,
           case when jsonb_typeof(e.v->'contact_rule') = 'object' then e.v->'contact_rule' end as rule
      from jsonb_array_elements(p_payload->'candidates') with ordinality e(v, ord)
  )
  select c.ord, c.ref, c.v, coalesce(x.id, gen_random_uuid()) as id, x.id is null as is_new,
         c.rule->>'rule' as rule, btrim(c.rule->>'reason') as reason,
         coalesce(nullif(c.v->>'source_key', ''), 'imported') as source_key,
         app.candidate_payload_problems(c.v)
         || case when c.ref is null then array['no zoho_id'] else '{}'::text[] end
         || case when c.ref is not null and count(*) over (partition by c.ref) > 1
                 then array['zoho_id appears twice in the payload'] else '{}'::text[] end
         || case when c.v->'contact_rule' is not null and jsonb_typeof(c.v->'contact_rule') not in ('object', 'null')
                   then array['contact_rule must be an object']
                 when c.rule is not null and coalesce(c.rule->>'rule', '') not in ('do_not_contact', 'contact_later')
                   then array[format('contact rule "%s" is unknown', c.rule->>'rule')]
                 when c.rule is not null and nullif(btrim(coalesce(c.rule->>'reason', '')), '') is null
                   then array['the contact rule needs a reason']
                 else '{}'::text[] end
         || app.zoho_stamp_problems(c.v, array['last_activity_at']) as problems
    from c
    left join public.candidates x on x.provider = 'zoho_recruit' and x.provider_ref = c.ref;

  create temp table zoho_jv_app on commit drop as
  with a as (
    select e.v, e.ord,
           nullif(btrim(coalesce(e.v->>'candidate_zoho_id', '')), '') as cand_ref,
           nullif(btrim(coalesce(e.v->>'job_display_id', '')), '') as job_ref
      from jsonb_array_elements(coalesce(p_payload->'applications', '[]'::jsonb)) with ordinality e(v, ord)
  ), r as (
    select a.*, c.id as candidate_id, c.is_new as candidate_is_new, c.problems as candidate_problems,
           c.source_key, c.v->>'last_activity_at' as candidate_activity,
           j.n as job_matches, j.job_id, j.company_id,
           s.key as sub_status_key, s.stage_key, s.outcome,
           -- The Candidate Owner, else the first of the Assigned Recruiter(s)
           -- (the extract already keeps one; "; " or ", " separate several).
           coalesce(nullif(btrim(coalesce(c.v->>'owner_name', '')), ''),
                    (select btrim(t.name)
                       from regexp_split_to_table(coalesce(a.v->>'owner_name', ''), '[;,]') with ordinality t(name, i)
                      where btrim(t.name) <> '' order by t.i limit 1)) as owner_name
      from a
      left join lateral (select * from pg_temp.zoho_jv_cand c where c.ref = a.cand_ref order by c.ord limit 1) c on true
      left join pg_temp.zoho_jv_jobs j on j.display_id = a.job_ref
      left join public.application_sub_statuses s on s.key = a.v->>'sub_status_key' and s.archived_at is null
  )
  select r.ord, r.cand_ref || ':' || r.job_ref as ref, r.v, r.cand_ref, r.job_ref,
         r.candidate_id, r.job_id, r.company_id, r.sub_status_key, r.stage_key, r.source_key, r.owner_name,
         p.person_id as owner_id, x.id is null as is_new,
         coalesce(case when app.is_timestamptz(r.v->>'received_at') then (r.v->>'received_at')::timestamptz end,
                  case when app.is_timestamptz(r.v->>'status_at') then (r.v->>'status_at')::timestamptz end,
                  case when app.is_timestamptz(r.candidate_activity) then r.candidate_activity::timestamptz end,
                  now()) as received_at,
         case when r.cand_ref is null then array['no candidate_zoho_id'] else '{}'::text[] end
         || case when r.job_ref is null then array['no job_display_id'] else '{}'::text[] end
         || case when r.cand_ref is not null and r.candidate_id is null
                   then array[format('candidate %s is not in the payload', r.cand_ref)]
                 when cardinality(r.candidate_problems) > 0
                   then array[format('candidate %s is refused', r.cand_ref)]
                 else '{}'::text[] end
         || case when r.job_ref is not null and r.job_id is null
                   then array[format('job %s is not in the database', r.job_ref)]
                 when r.job_matches > 1
                   then array[format('job %s matches %s jobs', r.job_ref, r.job_matches)]
                 else '{}'::text[] end
         || case when r.sub_status_key is null
                 then array[format('status "%s" is unknown', coalesce(r.v->>'sub_status_key', '(none)'))]
                 else '{}'::text[] end
         || case when r.cand_ref is not null and r.job_ref is not null
                      and count(*) over (partition by r.cand_ref, r.job_ref) > 1
                 then array['the candidate and job appear twice in the payload'] else '{}'::text[] end
         || app.zoho_stamp_problems(r.v, array['received_at', 'status_at'])
         -- An application in play from another source (added by hand) for
         -- the same candidate and job: one open application per candidate.
         || case when x.id is null and r.outcome = 'open' and not coalesce(r.candidate_is_new, true)
                      and exists (select 1 from public.applications o
                                   where o.job_id = r.job_id and o.candidate_id = r.candidate_id and o.in_play)
                 then array['already has an open application for this job'] else '{}'::text[] end
         as problems
    from r
    left join pg_temp.zoho_jv_people p on p.name_key = lower(r.owner_name)
    left join public.applications x
           on x.job_id = r.job_id and x.source_provider = 'zoho_recruit' and x.provider_ref = r.cand_ref || ':' || r.job_ref;

  create temp table zoho_jv_note on commit drop as
  with n as (
    select e.v, e.ord,
           nullif(btrim(coalesce(e.v->>'candidate_zoho_id', '')), '') || ':'
             || nullif(btrim(coalesce(e.v->>'job_display_id', '')), '') as app_ref,
           btrim(coalesce(e.v->>'seq', '')) as seq,
           btrim(coalesce(e.v->>'body', '')) as body,
           nullif(btrim(coalesce(e.v->>'kind_label', '')), '') as kind_label,
           nullif(btrim(coalesce(e.v->>'author_name', '')), '') as author_name
      from jsonb_array_elements(coalesce(p_payload->'notes', '[]'::jsonb)) with ordinality e(v, ord)
  )
  select n.ord, n.app_ref || ':' || n.seq as ref, n.app_ref, n.kind_label, n.author_name,
         a.candidate_id, a.company_id, a.job_ref, p.person_id as actor_id,
         coalesce(cardinality(a.problems) > 0, false) as application_refused,
         n.body = '' as without_text,
         length(n.body) > 4000 as truncated,
         case when n.body = '' then coalesce(n.kind_label, 'Note')
              when length(n.body) > 4000 then left(n.body, 3999) || '…'
              else n.body end as body,
         coalesce(case when app.is_timestamptz(n.v->>'occurred_at') then (n.v->>'occurred_at')::timestamptz end,
                  a.received_at, now()) as occurred_at,
         x.id is null as is_new,
         case when n.app_ref is null then array['no candidate_zoho_id or job_display_id']
              when a.ref is null then array[format('application %s is not in the payload', n.app_ref)]
              else '{}'::text[] end
         || case when n.seq !~ '^[1-9][0-9]{0,5}$' then array[format('seq "%s" is not a positive number', n.seq)]
                 else '{}'::text[] end
         || case when n.app_ref is not null and count(*) over (partition by n.app_ref, n.seq) > 1
                 then array['the note appears twice in the payload'] else '{}'::text[] end
         || app.zoho_stamp_problems(n.v, array['occurred_at']) as problems
    from n
    left join lateral (select * from pg_temp.zoho_jv_app a where a.ref = n.app_ref order by a.ord limit 1) a on true
    left join pg_temp.zoho_jv_people p on p.name_key = lower(n.author_name)
    left join public.candidate_notes x on x.provider = 'zoho_recruit' and x.provider_ref = n.app_ref || ':' || n.seq;
end $$;

-- ------------------------------------------------------------ pass 2: write
-- Writes the new rows the plan decided. Run only with nothing refused.
create or replace function app.zoho_job_view_write() returns void
language plpgsql security definer set search_path = public as $$
begin
  insert into public.candidates
    (id, full_name, email, phone, linkedin_url, skills, provider, provider_ref, source_key,
     do_not_contact, do_not_contact_reason, do_not_contact_at, contact_later, custom, last_activity_at)
  select c.id, btrim(c.v->>'full_name'), nullif(btrim(coalesce(c.v->>'email', '')), '')::citext,
         nullif(btrim(coalesce(c.v->>'phone', '')), ''), nullif(btrim(coalesce(c.v->>'linkedin_url', '')), ''),
         app.candidate_skills(c.v->'skills'), 'zoho_recruit', c.ref, c.source_key,
         c.rule is not distinct from 'do_not_contact',
         case when c.rule = 'do_not_contact' then c.reason end,
         case when c.rule = 'do_not_contact' then now() end,
         c.rule is not distinct from 'contact_later',
         app.jsonb_object_or_empty(c.v->'custom'),
         coalesce(nullif(c.v->>'last_activity_at', '')::timestamptz,
                  (select max(a.received_at) from pg_temp.zoho_jv_app a where a.cand_ref = c.ref), now())
    from pg_temp.zoho_jv_cand c
   where c.is_new
   order by c.ord;

  insert into public.applications
    (job_id, company_id, candidate_id, stage_key, sub_status_key, source_key, source_provider, provider_ref,
     owner_id, received_at, custom)
  select a.job_id, a.company_id, a.candidate_id, a.stage_key, a.sub_status_key, a.source_key, 'zoho_recruit', a.ref,
         a.owner_id, a.received_at, app.jsonb_object_or_empty(a.v->'custom')
    from pg_temp.zoho_jv_app a
   where a.is_new
   order by a.ord;

  insert into public.candidate_notes
    (candidate_id, company_id, kind, body, actor_id, actor_name, occurred_at, created_at, provider, provider_ref, custom)
  -- created_at = occurred_at (0070's convention): t8_touch_candidate reads a
  -- note's created_at, so a 2023 note leaves 2023 activity, not the import's.
  select n.candidate_id, n.company_id, 'note', n.body, n.actor_id, n.author_name, n.occurred_at, n.occurred_at,
         'zoho_recruit', n.ref,
         jsonb_build_object('zoho', jsonb_strip_nulls(jsonb_build_object('job_display_id', n.job_ref, 'kind_label', n.kind_label)))
    from pg_temp.zoho_jv_note n
   where n.is_new
   order by n.ord;
end $$;

-- ------------------------------------------------------ import_zoho_job_view
-- Returns { committed, candidates, applications, notes (new rows), by_status,
-- contact_rules, refused [{ref, reason}], unmatched_people [name], existing
-- (rows already there, skipped), notes_truncated, notes_without_text }.
create or replace function public.import_zoho_job_view(p_payload jsonb, p_commit boolean default false)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_prev_bulk text;
  v_prev_import text;
  v_refused jsonb;
  v_report jsonb;
  v_n int;
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  if not app.is_admin() then
    raise exception 'Importing from Zoho Recruit needs platform admin access.' using errcode = '42501';
  end if;
  if p_payload is null or jsonb_typeof(p_payload) <> 'object'
     or jsonb_typeof(p_payload->'candidates') is distinct from 'array'
     or coalesce(jsonb_typeof(p_payload->'applications'), 'array') <> 'array'
     or coalesce(jsonb_typeof(p_payload->'notes'), 'array') <> 'array' then
    raise exception 'The payload needs a "candidates" array (and "applications" and "notes" arrays when present).'
      using errcode = '22023';
  end if;

  perform app.zoho_job_view_plan(p_payload);

  select coalesce(jsonb_agg(jsonb_build_object('ref', r.ref, 'reason', r.reason) order by r.k, r.ord), '[]'::jsonb)
    into v_refused
    from (
      select 1 as k, ord, coalesce(ref, format('candidate #%s', ord)) as ref, array_to_string(problems, '; ') as reason
        from pg_temp.zoho_jv_cand where cardinality(problems) > 0
      union all
      select 2, ord, coalesce(ref, format('application #%s', ord)), array_to_string(problems, '; ')
        from pg_temp.zoho_jv_app where cardinality(problems) > 0
      union all
      select 3, ord, coalesce(ref, format('note #%s', ord)), array_to_string(problems, '; ')
        from pg_temp.zoho_jv_note where cardinality(problems) > 0
    ) r;

  v_report := jsonb_build_object(
    'candidates', (select count(*) from pg_temp.zoho_jv_cand where is_new and cardinality(problems) = 0),
    'applications', (select count(*) from pg_temp.zoho_jv_app where is_new and cardinality(problems) = 0),
    'notes', (select count(*) from pg_temp.zoho_jv_note
               where is_new and cardinality(problems) = 0 and not application_refused),
    'by_status', (select coalesce(jsonb_object_agg(g.sub_status_key, g.n), '{}'::jsonb)
                    from (select sub_status_key, count(*) as n from pg_temp.zoho_jv_app
                           where is_new and cardinality(problems) = 0 group by 1) g),
    'contact_rules', (select jsonb_build_object(
                        'do_not_contact', count(*) filter (where rule = 'do_not_contact'),
                        'contact_later', count(*) filter (where rule = 'contact_later'))
                        from pg_temp.zoho_jv_cand where is_new and cardinality(problems) = 0),
    'existing', jsonb_build_object(
      'candidates', (select count(*) from pg_temp.zoho_jv_cand where not is_new),
      'applications', (select count(*) from pg_temp.zoho_jv_app where not is_new),
      'notes', (select count(*) from pg_temp.zoho_jv_note where not is_new)),
    'notes_truncated', (select count(*) from pg_temp.zoho_jv_note where is_new and truncated),
    'notes_without_text', (select count(*) from pg_temp.zoho_jv_note where is_new and without_text),
    'refused', v_refused,
    'unmatched_people', (select coalesce(jsonb_agg(u.name order by u.name), '[]'::jsonb) from (
        select owner_name as name from pg_temp.zoho_jv_app where owner_name is not null and owner_id is null
        union
        select author_name from pg_temp.zoho_jv_note where author_name is not null and actor_id is null) u));

  v_n := jsonb_array_length(v_refused);
  if v_n > 0 and coalesce(p_commit, false) then
    raise exception 'Import refused: % rows have problems.', v_n;
  end if;
  if not coalesce(p_commit, false) then
    return jsonb_build_object('committed', false) || v_report;
  end if;

  -- ================================================================ pass 2
  -- app.bulk_import: no notification, no per-row audit, no job filled or
  -- closed. app.candidate_import: a do-not-contact candidate's applications
  -- still go in (0067's guard_application_contact bypass).
  v_prev_bulk := current_setting('app.bulk_import', true);
  v_prev_import := current_setting('app.candidate_import', true);
  perform set_config('app.bulk_import', 'on', true);
  perform set_config('app.candidate_import', 'on', true);

  perform app.zoho_job_view_write();

  select count(*) into v_n from public.candidates
   where provider = 'zoho_recruit' and provider_ref in (select ref from pg_temp.zoho_jv_cand);
  if v_n <> (select count(*) from pg_temp.zoho_jv_cand) then
    raise exception 'Verification failed: % candidates planned, % found — nothing was written.',
      (select count(*) from pg_temp.zoho_jv_cand), v_n;
  end if;
  select count(*) into v_n from public.applications a
    join pg_temp.zoho_jv_app p on p.job_id = a.job_id and a.source_provider = 'zoho_recruit' and a.provider_ref = p.ref;
  if v_n <> (select count(*) from pg_temp.zoho_jv_app) then
    raise exception 'Verification failed: % applications planned, % found — nothing was written.',
      (select count(*) from pg_temp.zoho_jv_app), v_n;
  end if;
  select count(*) into v_n from public.candidate_notes
   where provider = 'zoho_recruit' and provider_ref in (select ref from pg_temp.zoho_jv_note);
  if v_n <> (select count(*) from pg_temp.zoho_jv_note) then
    raise exception 'Verification failed: % notes planned, % found — nothing was written.',
      (select count(*) from pg_temp.zoho_jv_note), v_n;
  end if;

  perform set_config('app.bulk_import', coalesce(nullif(v_prev_bulk, ''), 'off'), true);
  perform set_config('app.candidate_import', coalesce(nullif(v_prev_import, ''), 'off'), true);

  insert into public.activity_log (actor_person_id, actor_user_id, entity_type, entity_id, action, after)
    values (v_me, auth.uid(), 'imports', null, 'zoho_job_view', v_report - 'refused' - 'unmatched_people');
  return jsonb_build_object('committed', true) || v_report;
end $$;

-- Run by scripts/zoho-job-view-import.sh over the direct (superuser)
-- connection as the impersonated admin; never over the API.
revoke all on function
  app.is_timestamptz(text),
  app.zoho_stamp_problems(jsonb, text[]),
  app.zoho_job_view_plan(jsonb),
  app.zoho_job_view_write(),
  public.import_zoho_job_view(jsonb, boolean)
from public, anon, authenticated;

commit;
