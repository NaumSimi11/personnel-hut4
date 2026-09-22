-- 0070_zoho_history.sql
-- Candidate notes, and the Zoho interviews and reviews (plan 055). The two
-- seams 052 left: the notes that were about the person and not about one job
-- (counted then, imported now), and the interviews and reviews whose Zoho ids
-- were preserved but whose rows were never created.
--
-- Order: candidate_notes (table, RLS, touch, audit) → add_candidate_note →
-- the interviews / scorecards columns → import_zoho_history → grants. There
-- is nothing to backfill: every row this slice wants comes in through the
-- import, and the import is idempotent by (provider, provider_ref).

-- -------------------------------------------------------- candidate_notes
-- A note belongs to the person, not to one job (D1): the calls, messages and
-- status changes a recruiter needs when they open the record. `company_id` is
-- nullable and every imported note carries null — nothing ties Zoho's
-- person-level notes to a company that exists here. A note written from a
-- company's side may tag it, and then that company's candidates.view holders
-- read it too.
--
-- `actor_id` is the person who did it when we could link them; `actor_name`
-- carries the Zoho user we could not. `occurred_at` is when it happened (the
-- Zoho date), `created_at` when the row was written — the import sets both to
-- the Zoho date, so an imported 2023 note leaves a 2023 activity (0067's
-- rule). D2's kinds are a CHECK list, not a lookup: history needs a
-- vocabulary, not a table anyone edits. The verbatim Zoho type is kept in
-- custom.zoho.type.
create table public.candidate_notes (
  id uuid primary key default gen_random_uuid(),
  candidate_id uuid not null references public.candidates(id) on delete cascade,
  company_id uuid references public.companies(id),
  kind text not null default 'note' check (kind in (
    'note', 'call', 'message', 'meeting', 'status_change',
    'association', 'unassociation', 'review', 'task', 'other')),
  body text not null check (length(body) between 1 and 4000),
  actor_id uuid references public.people(id),
  actor_name text,
  occurred_at timestamptz not null default now(),
  provider text,
  provider_ref text check (provider_ref is null or provider is not null),
  custom jsonb not null default '{}'::jsonb check (jsonb_typeof(custom) = 'object'),
  created_at timestamptz not null default now()
);
create index candidate_notes_candidate_idx on public.candidate_notes (candidate_id, occurred_at desc);
-- Idempotence: a second import run finds its own rows and writes nothing.
create unique index candidate_notes_provider_dedupe
  on public.candidate_notes (provider, provider_ref) where provider_ref is not null;

-- The pool's own touch (0067): a note is activity on the candidate, and
-- last_activity_at only ever moves forward. The trigger function's third
-- branch reads new.candidate_id / new.created_at, which is exactly this
-- table's shape, so it is reused rather than copied.
create trigger t8_touch_candidate after insert on public.candidate_notes
  for each row execute function app.touch_candidate_activity();

-- There is no edit path (a note is history), so the audit exists for the
-- removal: who took a note off a record, and what it said.
create trigger audit after insert or delete on public.candidate_notes
  for each row execute function app.audit();

-- RLS. Reading is the pool capability, or candidates.view in the company the
-- note is tagged with. There is no insert or update policy: the RPC and the
-- import are the only writers, both security definer and owned by postgres.
-- Removing is the author's own, or an admin's.
alter table public.candidate_notes enable row level security;
create policy sel on public.candidate_notes for select to authenticated
  using (app.can_source_candidates()
         or (company_id is not null and app.has_capability(company_id, 'candidates.view')));
create policy del on public.candidate_notes for delete to authenticated
  using (actor_id = app.current_person_id() or app.is_admin());
grant select, delete on public.candidate_notes to authenticated;
grant all on public.candidate_notes to service_role;

-- ----------------------------------------------------- add_candidate_note
-- The one door the app uses. A pool holder writes about the person; the note
-- lands with no company (D1) and the caller as its actor.
create or replace function public.add_candidate_note(p_candidate_id uuid, p_body text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_body text := trim(coalesce(p_body, ''));
  v_candidate record;
  v_id uuid;
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  if not app.can_source_candidates() then
    raise exception 'You need "Work the talent pool" to add a note to a candidate.' using errcode = '42501';
  end if;
  select id, full_name, archived_at into v_candidate
    from public.candidates where id = p_candidate_id;
  if not found then
    raise exception 'That candidate is not in the talent pool.' using errcode = '22023';
  end if;
  if v_candidate.archived_at is not null then
    raise exception '% is archived — restore them first.', v_candidate.full_name using errcode = '22023';
  end if;
  if length(v_body) = 0 then
    raise exception 'Write the note first.' using errcode = '22023';
  end if;
  if length(v_body) > 4000 then
    raise exception 'Keep the note to 4,000 characters or fewer.' using errcode = '22023';
  end if;

  insert into public.candidate_notes (candidate_id, company_id, kind, body, actor_id)
    values (p_candidate_id, null, 'note', v_body, v_me)
    returning id into v_id;
  return jsonb_build_object('id', v_id);
end $$;

-- ------------------------------------------- interviews and scorecards (D3/D4)
-- Provenance on both tables, in the shape 0067 gave candidates and files.
alter table public.interviews
  add column provider text,
  add column provider_ref text,
  add column custom jsonb not null default '{}'::jsonb;
alter table public.interviews
  add constraint interviews_provider_ref_shape check (provider_ref is null or provider is not null),
  add constraint interviews_custom_is_object check (jsonb_typeof(custom) = 'object');
create unique index interviews_provider_dedupe
  on public.interviews (provider, provider_ref) where provider_ref is not null;

-- A Zoho review whose creator is not one of our people still has to be
-- readable, so author_id becomes nullable and author_name carries the name.
-- The CHECK keeps a card from being anonymous on both sides.
--
-- No RLS policy changes. `unique (interview_id, author_id)` keeps working —
-- nulls are distinct, so several unlinked reviewers may sit on one interview.
-- The `sel` policy's first branch (author_id = app.current_person_id())
-- yields NULL for a null author and never matches, so readers fall through to
-- the capability branch, which is what we want: an imported card is visible
-- to candidates.view holders under the same blind rule. The `ins` and `upd`
-- policies compare author_id to the caller, so no client can write or edit a
-- null-author card; only this migration's import (security definer, owned by
-- postgres, so outside RLS) does.
alter table public.scorecards
  alter column author_id drop not null,
  add column author_name text,
  add column provider text,
  add column provider_ref text;
alter table public.scorecards
  add constraint scorecards_provider_ref_shape check (provider_ref is null or provider is not null),
  add constraint scorecards_author_present check (author_id is not null or author_name is not null);
create unique index scorecards_provider_dedupe
  on public.scorecards (provider, provider_ref) where provider_ref is not null;

-- ------------------------------------------------------------------ helper
-- A Zoho timestamp that will not parse must be a named problem, not an
-- exception from the middle of a loop, so the cast is tried in one place.
-- Null means "absent or unparseable"; the caller knows which by looking at
-- the text it passed.
create or replace function app.zoho_history_ts(p text) returns timestamptz
language plpgsql stable security definer set search_path = public as $$
begin
  if nullif(trim(coalesce(p, '')), '') is null then return null; end if;
  return p::timestamptz;
exception when others then
  return null;
end $$;

-- ----------------------------------------------------- import_zoho_history
-- The 0067 shape and discipline: pass 1 decides every row, p_commit = false
-- reports without writing, p_commit = true writes all or nothing.
--
-- Two kinds of "no": a row we cannot place (its candidate, application or
-- interview is not here, or it is already imported, or its author already
-- scored this interview) is *skipped* — counted by reason, reported, and the
-- call still succeeds, because history is full of rows that point outside
-- what we imported. A row that is malformed (no id, an unreadable date, a
-- body over 4,000 characters) is a *problem*: the dry run lists them and a
-- commit refuses, exactly as 0067 does.
create or replace function public.import_zoho_history(p_payload jsonb, p_commit boolean default false)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_row jsonb;
  v_problems text[];
  v_all_problems jsonb := '[]'::jsonb;
  v_refused int := 0;
  v_skipped jsonb := '[]'::jsonb;
  -- resolved lookups (jsonb dictionaries, 0028/0067 style)
  v_person_by_email jsonb := '{}'::jsonb;
  v_user_person jsonb := '{}'::jsonb;   -- zoho user id -> person uuid
  v_user_name jsonb := '{}'::jsonb;     -- zoho user id -> name
  v_users_resolved int := 0;
  v_users_unresolved int := 0;
  v_info jsonb;
  v_counts jsonb;
  v_kinds text[] := array['note', 'call', 'message', 'meeting', 'status_change',
                          'association', 'unassociation', 'review', 'task', 'other'];
  v_email text;
  v_name text;
  v_txt text;
  v_person uuid;
  v_cand uuid;
  v_job uuid;
  v_app uuid;
  v_id uuid;
  v_author uuid;
  v_at timestamptz;
  v_when timestamptz;
  v_panel jsonb;
  v_unresolved jsonb;
  v_zoho jsonb;
  v_rating int;
  v_minutes int;
  v_n int;
  v_notes_created int := 0;
  v_notes_skipped int := 0;
  v_notes_written int := 0;
  v_ints_created int := 0;
  v_ints_skipped int := 0;
  v_ints_written int := 0;
  v_panel_rows int := 0;
  v_panel_written int := 0;
  v_cards_created int := 0;
  v_cards_skipped int := 0;
  v_cards_written int := 0;
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  if not app.is_admin() then
    raise exception 'Importing from Zoho Recruit needs platform admin access.' using errcode = '42501';
  end if;
  if p_payload is null or jsonb_typeof(p_payload) <> 'object' then
    raise exception 'The payload needs "candidate_notes", "interviews" and "reviews" arrays.' using errcode = '22023';
  end if;
  foreach v_txt in array array['candidate_notes', 'interviews', 'reviews'] loop
    if p_payload ? v_txt and jsonb_typeof(p_payload->v_txt) <> 'array' then
      raise exception 'The payload needs "candidate_notes", "interviews" and "reviews" arrays.' using errcode = '22023';
    end if;
  end loop;

  if to_regclass('pg_temp.zoho_history_rows') is not null then
    drop table pg_temp.zoho_history_rows;
  end if;
  create temp table zoho_history_rows (
    kind text not null, ref text not null, info jsonb not null, primary key (kind, ref)
  ) on commit drop;

  -- ---------------------------------------------------------------- users
  -- 0067's rule, unchanged: people by work email, and the generic hr@ /
  -- admin@ accounts never map to a person.
  select coalesce(jsonb_object_agg(lower(work_email::text), id), '{}'::jsonb) into v_person_by_email
    from public.people where work_email is not null and archived_at is null;
  for v_row in select * from jsonb_array_elements(coalesce(p_payload->'users', '[]'::jsonb)) loop
    v_email := lower(trim(coalesce(v_row->>'email', '')));
    v_person := case when v_email <> '' and v_email not like 'hr@%' and v_email not like 'admin@%'
                     then (v_person_by_email->>v_email)::uuid end;
    v_user_name := v_user_name || jsonb_build_object(v_row->>'zoho_id',
      coalesce(nullif(trim(coalesce(v_row->>'name', '')), ''), nullif(v_email, ''), v_row->>'zoho_id'));
    if v_person is not null then
      v_user_person := v_user_person || jsonb_build_object(v_row->>'zoho_id', v_person);
      v_users_resolved := v_users_resolved + 1;
    else
      v_users_unresolved := v_users_unresolved + 1;
    end if;
  end loop;

  -- -------------------------------------------------------- pass 1: notes
  for v_row in select * from jsonb_array_elements(coalesce(p_payload->'candidate_notes', '[]'::jsonb)) loop
    v_problems := '{}';
    if nullif(v_row->>'zoho_id', '') is null then v_problems := array_append(v_problems, 'no zoho_id'); end if;
    if exists (select 1 from pg_temp.zoho_history_rows where kind = 'note' and ref = v_row->>'zoho_id') then
      v_problems := array_append(v_problems, 'zoho_id appears twice in the extract');
    end if;
    if length(trim(coalesce(v_row->>'body', ''))) = 0 then
      v_problems := array_append(v_problems, 'the note has no body');
    elsif length(v_row->>'body') > 4000 then
      v_problems := array_append(v_problems, 'the body is longer than 4,000 characters');
    end if;
    v_at := app.zoho_history_ts(v_row->>'created_at');
    if nullif(trim(coalesce(v_row->>'created_at', '')), '') is not null and v_at is null then
      v_problems := array_append(v_problems, format('created_at "%s" is not a date', v_row->>'created_at'));
    end if;
    if cardinality(v_problems) > 0 then
      v_all_problems := v_all_problems || jsonb_build_object('kind', 'note', 'ref', v_row->>'zoho_id',
        'problems', to_jsonb(v_problems));
      v_refused := v_refused + 1;
      continue;
    end if;

    -- An unknown kind is corrected, never refused: a type nobody recognises
    -- is still a note somebody wrote (the verbatim type stays in custom).
    v_txt := coalesce(nullif(v_row->>'kind', ''), 'note');
    if not (v_txt = any (v_kinds)) then v_txt := 'other'; end if;

    select id into v_cand from public.candidates
      where provider = 'zoho_recruit' and provider_ref = coalesce(v_row->>'candidate_zoho_id', '');
    if v_cand is null then
      v_skipped := v_skipped || jsonb_build_object('kind', 'note', 'ref', v_row->>'zoho_id',
        'reason', 'candidate_missing');
      v_notes_skipped := v_notes_skipped + 1;
      insert into pg_temp.zoho_history_rows values ('note', v_row->>'zoho_id', jsonb_build_object('create', false));
      continue;
    end if;
    if exists (select 1 from public.candidate_notes
                where provider = 'zoho_recruit' and provider_ref = v_row->>'zoho_id') then
      v_skipped := v_skipped || jsonb_build_object('kind', 'note', 'ref', v_row->>'zoho_id',
        'reason', 'already_imported');
      v_notes_skipped := v_notes_skipped + 1;
      insert into pg_temp.zoho_history_rows values ('note', v_row->>'zoho_id', jsonb_build_object('create', false));
      continue;
    end if;
    v_notes_created := v_notes_created + 1;
    insert into pg_temp.zoho_history_rows values ('note', v_row->>'zoho_id', jsonb_build_object(
      'create', true, 'candidate_id', v_cand, 'kind', v_txt, 'at', coalesce(v_at, now())));
  end loop;

  -- --------------------------------------------------- pass 1: interviews
  for v_row in select * from jsonb_array_elements(coalesce(p_payload->'interviews', '[]'::jsonb)) loop
    v_problems := '{}';
    if nullif(v_row->>'zoho_id', '') is null then v_problems := array_append(v_problems, 'no zoho_id'); end if;
    if exists (select 1 from pg_temp.zoho_history_rows where kind = 'interview' and ref = v_row->>'zoho_id') then
      v_problems := array_append(v_problems, 'zoho_id appears twice in the extract');
    end if;
    v_when := app.zoho_history_ts(v_row->>'scheduled_at');
    if v_when is null then
      v_problems := array_append(v_problems,
        case when nullif(trim(coalesce(v_row->>'scheduled_at', '')), '') is null then 'no scheduled_at'
             else format('scheduled_at "%s" is not a date', v_row->>'scheduled_at') end);
    end if;
    v_at := app.zoho_history_ts(v_row->>'created_at');
    if nullif(trim(coalesce(v_row->>'created_at', '')), '') is not null and v_at is null then
      v_problems := array_append(v_problems, format('created_at "%s" is not a date', v_row->>'created_at'));
    end if;
    -- The clamp is the server's (D3), applied again here so a dry run that
    -- says "all good" cannot be followed by a commit that dies on a cast.
    v_minutes := null;
    begin
      v_minutes := least(greatest(coalesce(nullif(trim(coalesce(v_row->>'duration_minutes', '')), '')::int, 60), 15), 480);
    exception when others then
      v_problems := array_append(v_problems,
        format('duration_minutes "%s" is not a whole number', v_row->>'duration_minutes'));
    end;
    -- The status is the outcome we keep (cancelled or completed): a word we
    -- do not know would change what the row means, so it is a problem — the
    -- 0067 rule for a job status.
    if coalesce(v_row->>'status', '') not in ('scheduled', 'completed', 'cancelled') then
      v_problems := array_append(v_problems, format('status "%s" is not an interview status', v_row->>'status'));
    end if;
    if cardinality(v_problems) > 0 then
      v_all_problems := v_all_problems || jsonb_build_object('kind', 'interview', 'ref', v_row->>'zoho_id',
        'problems', to_jsonb(v_problems));
      v_refused := v_refused + 1;
      continue;
    end if;

    select id into v_cand from public.candidates
      where provider = 'zoho_recruit' and provider_ref = coalesce(v_row->>'candidate_zoho_id', '');
    if v_cand is null then
      v_skipped := v_skipped || jsonb_build_object('kind', 'interview', 'ref', v_row->>'zoho_id',
        'reason', 'candidate_missing');
      v_ints_skipped := v_ints_skipped + 1;
      insert into pg_temp.zoho_history_rows values ('interview', v_row->>'zoho_id', jsonb_build_object('create', false));
      continue;
    end if;
    -- The job's Zoho id lives in custom->'zoho'->>'id' (0067); the pair is
    -- the application. An imported application is preferred when a candidate
    -- somehow has two on one job.
    select id into v_job from public.jobs where custom->'zoho'->>'id' = coalesce(v_row->>'job_zoho_id', '');
    v_app := null;
    if v_job is not null then
      select id into v_app from public.applications
        where candidate_id = v_cand and job_id = v_job
        order by (source_provider = 'zoho_recruit') desc, created_at
        limit 1;
    end if;
    if v_app is null then
      v_skipped := v_skipped || jsonb_build_object('kind', 'interview', 'ref', v_row->>'zoho_id',
        'reason', 'application_missing');
      v_ints_skipped := v_ints_skipped + 1;
      insert into pg_temp.zoho_history_rows values ('interview', v_row->>'zoho_id', jsonb_build_object('create', false));
      continue;
    end if;
    select id into v_id from public.interviews
      where provider = 'zoho_recruit' and provider_ref = v_row->>'zoho_id';
    if v_id is not null then
      v_skipped := v_skipped || jsonb_build_object('kind', 'interview', 'ref', v_row->>'zoho_id',
        'reason', 'already_imported');
      v_ints_skipped := v_ints_skipped + 1;
      -- The id is kept: this run's reviews still attach to it.
      insert into pg_temp.zoho_history_rows values ('interview', v_row->>'zoho_id',
        jsonb_build_object('create', false, 'id', v_id));
      continue;
    end if;

    v_panel := '[]'::jsonb;
    v_unresolved := '[]'::jsonb;
    if jsonb_typeof(v_row->'interviewer_zoho_ids') = 'array' then
      for v_txt in select distinct e from jsonb_array_elements_text(v_row->'interviewer_zoho_ids') e loop
        v_person := (v_user_person->>v_txt)::uuid;
        if v_person is not null then
          if not v_panel @> to_jsonb(v_person::text) then
            v_panel := v_panel || to_jsonb(v_person::text);
          end if;
        else
          v_name := coalesce(nullif(trim(coalesce(v_user_name->>v_txt, '')), ''), v_txt);
          if not v_unresolved @> to_jsonb(v_name) then
            v_unresolved := v_unresolved || to_jsonb(v_name);
          end if;
        end if;
      end loop;
    end if;

    v_id := gen_random_uuid();
    v_ints_created := v_ints_created + 1;
    v_panel_rows := v_panel_rows + jsonb_array_length(v_panel);
    insert into pg_temp.zoho_history_rows values ('interview', v_row->>'zoho_id', jsonb_build_object(
      'create', true, 'id', v_id, 'application_id', v_app,
      'scheduled_at', v_when, 'at', coalesce(v_at, v_when), 'duration', v_minutes,
      'panel', v_panel, 'unresolved', v_unresolved));
  end loop;

  -- ------------------------------------------------------ pass 1: reviews
  for v_row in select * from jsonb_array_elements(coalesce(p_payload->'reviews', '[]'::jsonb)) loop
    v_problems := '{}';
    if nullif(v_row->>'zoho_id', '') is null then v_problems := array_append(v_problems, 'no zoho_id'); end if;
    if exists (select 1 from pg_temp.zoho_history_rows where kind = 'review' and ref = v_row->>'zoho_id') then
      v_problems := array_append(v_problems, 'zoho_id appears twice in the extract');
    end if;
    v_rating := null;
    begin
      v_rating := (nullif(trim(coalesce(v_row->>'rating', '')), ''))::int;
    exception when others then
      v_rating := null;
    end;
    if v_rating is null or v_rating < 1 or v_rating > 4 then
      v_problems := array_append(v_problems, format('rating "%s" is not 1 to 4', coalesce(v_row->>'rating', '(none)')));
    end if;
    if coalesce(v_row->>'recommendation', '') not in ('strong_no', 'no', 'yes', 'strong_yes') then
      v_problems := array_append(v_problems,
        format('recommendation "%s" is not one of strong_no, no, yes, strong_yes', v_row->>'recommendation'));
    end if;
    v_at := app.zoho_history_ts(v_row->>'created_at');
    if nullif(trim(coalesce(v_row->>'created_at', '')), '') is not null and v_at is null then
      v_problems := array_append(v_problems, format('created_at "%s" is not a date', v_row->>'created_at'));
    end if;
    if cardinality(v_problems) > 0 then
      v_all_problems := v_all_problems || jsonb_build_object('kind', 'review', 'ref', v_row->>'zoho_id',
        'problems', to_jsonb(v_problems));
      v_refused := v_refused + 1;
      continue;
    end if;

    -- The interview is this run's (created or already imported), else one an
    -- earlier run wrote.
    select info into v_info from pg_temp.zoho_history_rows
      where kind = 'interview' and ref = coalesce(v_row->>'interview_zoho_id', '');
    v_id := nullif(v_info->>'id', '')::uuid;
    if v_id is null and v_info is null then
      select id into v_id from public.interviews
        where provider = 'zoho_recruit' and provider_ref = coalesce(v_row->>'interview_zoho_id', '');
    end if;
    if v_id is null then
      v_skipped := v_skipped || jsonb_build_object('kind', 'review', 'ref', v_row->>'zoho_id',
        'reason', 'interview_missing');
      v_cards_skipped := v_cards_skipped + 1;
      insert into pg_temp.zoho_history_rows values ('review', v_row->>'zoho_id', jsonb_build_object('create', false));
      continue;
    end if;
    if exists (select 1 from public.scorecards
                where provider = 'zoho_recruit' and provider_ref = v_row->>'zoho_id') then
      v_skipped := v_skipped || jsonb_build_object('kind', 'review', 'ref', v_row->>'zoho_id',
        'reason', 'already_imported');
      v_cards_skipped := v_cards_skipped + 1;
      insert into pg_temp.zoho_history_rows values ('review', v_row->>'zoho_id', jsonb_build_object('create', false));
      continue;
    end if;

    -- One card per (interview, author) — the 0014 unique constraint. Nulls
    -- are distinct there, so only a resolved author can duplicate: against a
    -- card already in the database, or against an earlier row of this run.
    v_author := (v_user_person->>coalesce(v_row->>'author_zoho_id', ''))::uuid;
    if v_author is not null
       and (exists (select 1 from public.scorecards s
                     where s.interview_id = v_id and s.author_id = v_author)
            or exists (select 1 from pg_temp.zoho_history_rows
                        where kind = 'review_author' and ref = v_id::text || '|' || v_author::text)) then
      v_skipped := v_skipped || jsonb_build_object('kind', 'review', 'ref', v_row->>'zoho_id',
        'reason', 'duplicate_author');
      v_cards_skipped := v_cards_skipped + 1;
      insert into pg_temp.zoho_history_rows values ('review', v_row->>'zoho_id', jsonb_build_object('create', false));
      continue;
    end if;
    if v_author is not null then
      insert into pg_temp.zoho_history_rows values ('review_author', v_id::text || '|' || v_author::text,
        jsonb_build_object('review', v_row->>'zoho_id'));
    end if;

    v_cards_created := v_cards_created + 1;
    insert into pg_temp.zoho_history_rows values ('review', v_row->>'zoho_id', jsonb_build_object(
      'create', true, 'interview_id', v_id, 'author_id', v_author,
      'author_name', case when v_author is null
                          then coalesce(nullif(trim(coalesce(v_user_name->>coalesce(v_row->>'author_zoho_id', ''), '')), ''),
                                        'Zoho Recruit') end,
      'rating', v_rating, 'at', coalesce(v_at, now())));
  end loop;

  v_counts := jsonb_build_object(
    'notes_created', v_notes_created, 'notes_skipped', v_notes_skipped,
    'interviews_created', v_ints_created, 'interviews_skipped', v_ints_skipped,
    'panel_rows', v_panel_rows,
    'scorecards_created', v_cards_created, 'scorecards_skipped', v_cards_skipped,
    'users_resolved', v_users_resolved, 'users_unresolved', v_users_unresolved);

  if v_refused > 0 and p_commit then
    raise exception 'Import refused: % rows have problems. Fix the extract and run again.', v_refused;
  end if;
  if not p_commit then
    return jsonb_build_object('committed', false, 'counts', v_counts,
      'skipped', v_skipped, 'problems', v_all_problems);
  end if;

  -- ================================================================ pass 2
  -- The touch trigger sets and restores its own app.candidate_rpc flag, and
  -- this import writes no candidates or applications rows, so there is no
  -- flag to raise here.
  for v_row in select * from jsonb_array_elements(coalesce(p_payload->'candidate_notes', '[]'::jsonb)) loop
    select info into v_info from pg_temp.zoho_history_rows where kind = 'note' and ref = v_row->>'zoho_id';
    if v_info is null or not (v_info->>'create')::boolean then continue; end if;
    begin
      insert into public.candidate_notes
        (candidate_id, company_id, kind, body, actor_id, actor_name, occurred_at,
         provider, provider_ref, custom, created_at)
      values ((v_info->>'candidate_id')::uuid, null, v_info->>'kind', v_row->>'body',
              (v_user_person->>coalesce(v_row->>'actor_zoho_id', ''))::uuid,
              case when (v_user_person->>coalesce(v_row->>'actor_zoho_id', '')) is null
                   then coalesce(nullif(trim(coalesce(v_row->>'actor_name', '')), ''),
                                 nullif(trim(coalesce(v_user_name->>coalesce(v_row->>'actor_zoho_id', ''), '')), '')) end,
              (v_info->>'at')::timestamptz, 'zoho_recruit', v_row->>'zoho_id',
              jsonb_build_object('zoho', jsonb_strip_nulls(jsonb_build_object(
                'id', v_row->>'zoho_id', 'type', nullif(trim(coalesce(v_row->>'zoho_type', '')), '')))),
              (v_info->>'at')::timestamptz);
      v_notes_written := v_notes_written + 1;
    exception when others then
      raise exception 'Row % (note): %', v_row->>'zoho_id', sqlerrm;
    end;
  end loop;

  for v_row in select * from jsonb_array_elements(coalesce(p_payload->'interviews', '[]'::jsonb)) loop
    select info into v_info from pg_temp.zoho_history_rows where kind = 'interview' and ref = v_row->>'zoho_id';
    if v_info is null or not (v_info->>'create')::boolean then continue; end if;
    begin
      -- company_id is derived by the 0014 sync_company trigger.
      v_zoho := jsonb_strip_nulls(jsonb_build_object(
        'id', v_row->>'zoho_id',
        'name', nullif(trim(coalesce(v_row->>'name', '')), ''),
        'outcome', nullif(trim(coalesce(v_row->>'outcome', '')), ''),
        'cancellation_reason', nullif(trim(coalesce(v_row->>'cancellation_reason', '')), '')));
      if jsonb_array_length(v_info->'unresolved') > 0 then
        v_zoho := v_zoho || jsonb_build_object('interviewers', v_info->'unresolved');
      end if;
      insert into public.interviews
        (id, application_id, kind, scheduled_at, duration_minutes, location, notes, status,
         created_by, provider, provider_ref, custom, created_at, updated_at)
      values ((v_info->>'id')::uuid, (v_info->>'application_id')::uuid,
              case when coalesce(v_row->>'kind', '') in ('phone', 'technical', 'panel', 'final', 'other')
                   then v_row->>'kind' else 'other' end,
              (v_info->>'scheduled_at')::timestamptz,
              (v_info->>'duration')::int,
              nullif(trim(coalesce(v_row->>'location', '')), ''),
              nullif(trim(coalesce(v_row->>'notes', '')), ''),
              v_row->>'status',
              (v_user_person->>coalesce(v_row->>'owner_zoho_id', ''))::uuid,
              'zoho_recruit', v_row->>'zoho_id',
              jsonb_build_object('zoho', v_zoho),
              (v_info->>'at')::timestamptz, (v_info->>'at')::timestamptz);
      v_ints_written := v_ints_written + 1;
      for v_txt in select jsonb_array_elements_text(v_info->'panel') loop
        insert into public.interview_panel (interview_id, person_id)
          values ((v_info->>'id')::uuid, v_txt::uuid)
          on conflict do nothing;
        v_panel_written := v_panel_written + 1;
      end loop;
    exception when others then
      raise exception 'Row % (interview): %', v_row->>'zoho_id', sqlerrm;
    end;
  end loop;

  for v_row in select * from jsonb_array_elements(coalesce(p_payload->'reviews', '[]'::jsonb)) loop
    select info into v_info from pg_temp.zoho_history_rows where kind = 'review' and ref = v_row->>'zoho_id';
    if v_info is null or not (v_info->>'create')::boolean then continue; end if;
    begin
      -- application_id and company_id are derived by the 0014
      -- sync_scorecard_scope trigger. D4: Zoho's 1-4 is our 1-4, and the
      -- review's source goes into the label because scorecards carry no
      -- custom column.
      insert into public.scorecards
        (interview_id, application_id, company_id, author_id, author_name, ratings, recommendation,
         summary, submitted_at, provider, provider_ref)
      values ((v_info->>'interview_id')::uuid, null, null,
              nullif(v_info->>'author_id', '')::uuid, v_info->>'author_name',
              jsonb_build_array(jsonb_build_object(
                'criterion_id', 'zoho_overall',
                'label', case when nullif(trim(coalesce(v_row->>'source', '')), '') is null
                              then 'Overall (Zoho Recruit)'
                              else format('Overall (Zoho Recruit · %s)', trim(v_row->>'source')) end,
                'rating', (v_info->>'rating')::int,
                'evidence', coalesce(nullif(trim(coalesce(v_row->>'comments', '')), ''), ''))),
              v_row->>'recommendation',
              coalesce(nullif(trim(coalesce(v_row->>'summary', '')), ''),
                       nullif(trim(coalesce(v_row->>'comments', '')), '')),
              (v_info->>'at')::timestamptz, 'zoho_recruit', v_row->>'zoho_id');
      v_cards_written := v_cards_written + 1;
    exception when others then
      raise exception 'Row % (review): %', v_row->>'zoho_id', sqlerrm;
    end;
  end loop;

  -- --------------------------------------------------------- verification
  -- What pass 1 planned is what pass 2 wrote, or the whole call rolls back.
  if v_notes_written <> v_notes_created or v_ints_written <> v_ints_created
     or v_panel_written <> v_panel_rows or v_cards_written <> v_cards_created then
    raise exception 'Verification failed: % notes, % interviews, % panel rows and % scorecards planned, '
                    '% / % / % / % written — nothing was written.',
      v_notes_created, v_ints_created, v_panel_rows, v_cards_created,
      v_notes_written, v_ints_written, v_panel_written, v_cards_written;
  end if;
  select count(*) into v_n from public.candidate_notes
    where provider = 'zoho_recruit' and provider_ref in (select ref from pg_temp.zoho_history_rows where kind = 'note');
  if v_n < v_notes_created then
    raise exception 'Verification failed: % notes planned, % found — nothing was written.', v_notes_created, v_n;
  end if;

  insert into public.activity_log (actor_person_id, actor_user_id, entity_type, entity_id, action, after)
    values (v_me, auth.uid(), 'zoho_history_import', null, 'INSERT', v_counts);
  return jsonb_build_object('committed', true, 'counts', v_counts,
    'skipped', v_skipped, 'problems', v_all_problems);
end $$;

-- ------------------------------------------------------------------ grants
-- The timestamp helper has one caller, the import, and is postgres-only.
revoke all on function app.zoho_history_ts(text) from public;
revoke all on function
  public.add_candidate_note(uuid, text),
  public.import_zoho_history(jsonb, boolean)
from public, anon;
grant execute on function
  public.add_candidate_note(uuid, text),
  public.import_zoho_history(jsonb, boolean)
to authenticated;
grant execute on function public.import_zoho_history(jsonb, boolean) to service_role;
