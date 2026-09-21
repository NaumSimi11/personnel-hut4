-- 0067_talent_pool.sql
-- Sourcing — the talent pool (plan 052). The candidate becomes a first-class
-- holding-wide record behind a deliberately granted capability
-- (candidates.source), every door dedupes without ever merging, the CV lives
-- on the candidate, the contact rule (never / contact later) is enforced by
-- the database, and the Zoho Recruit export comes in through the same door a
-- LinkedIn export will use later (upsert_sourced_candidate / import_zoho_recruit).
--
-- Order: capability → lookup → helpers → columns and indexes → backfills →
-- triggers and audit → candidate_files and storage → functions → grants →
-- report. Backfills run before any new trigger exists, so they leave no
-- candidate audit rows and never meet the field guard.

-- ------------------------------------------------------------ capability
insert into public.capabilities (key, group_name, label, sensitive, sort_order) values
  ('candidates.source', 'Recruitment', 'Work the talent pool (holding-wide)', false, 75)
on conflict (key) do nothing;
insert into public.capability_dependencies (capability_key, requires_key) values
  ('candidates.source', 'candidates.view')
on conflict do nothing;
-- Holding HR and Recruiter presets only (0002's rule: preset edits never
-- change existing grants). Company HR and Hiring Manager were accidental
-- pool readers through the 0006 "no applications yet" fallback; that ends here.
with caps(preset, cap) as (values
  ('Holding HR', 'candidates.source'), ('Recruiter', 'candidates.source')
), p as (select id, name from public.permission_presets where company_id is null)
insert into public.preset_capabilities (preset_id, capability_key)
select p.id, caps.cap from caps join p on p.name = caps.preset
on conflict do nothing;

-- ---------------------------------------------------------------- lookup
-- How a person came to HR's attention. `channels` stay publishing
-- destinations; `careers_page` and `added_by_hand` carry the labels the
-- recruitment report already shows for the careers channel / no source.
create table public.candidate_sources (
  key text primary key check (key ~ '^[a-z][a-z0-9_]{1,39}$'),
  label text not null,
  sort_order int not null default 0,
  archived_at timestamptz
);
insert into public.candidate_sources (key, label, sort_order) values
  ('head_hunt',        'Head hunt',                  10),
  ('linkedin_profile', 'LinkedIn profile capture',   20),
  ('linkedin_ad',      'LinkedIn advertisement',     30),
  ('careers_page',     'Company careers page',       40),
  ('job_board',        'Job board or advertisement', 50),
  ('referral',         'Referral',                   60),
  ('added_by_hand',    'Added by hand',              70),
  ('imported',         'Imported, source unknown',   80);
alter table public.candidate_sources enable row level security;
create policy read_all on public.candidate_sources for select to authenticated using (true);
create policy admin_write on public.candidate_sources for all to authenticated
  using (app.is_admin()) with check (app.is_admin());
grant select on public.candidate_sources to authenticated;
grant all on public.candidate_sources to service_role;

-- --------------------------------------------------------------- helpers
-- Key helpers feed stored generated columns, so they are declared immutable
-- and contain no current_setting / now(). The sort-and-join of name_key lives
-- only here (array_to_string is STABLE in pg_proc; an inline expression on
-- the column is refused with 42P17).

-- The last eight digits when at least eight are present; never written back
-- into `phone` (the stored phone stays verbatim).
create or replace function app.phone_key(p text) returns text
language sql immutable strict as $$
  select case when length(d) >= 8 then right(d, 8) end
  from (select regexp_replace(p, '[^0-9]', '', 'g') as d) s
$$;

-- Lower-cased, Latin diacritics folded, bracketed parts dropped, non-letters
-- to spaces, words sorted and joined. A suggestion key, never an identity:
-- "Dimitar (Benjamin) Iliev" and "Iliev Dimitar" → "dimitar iliev".
create or replace function app.name_key(p text) returns text
language sql immutable strict as $$
  select nullif(array_to_string((
    select array_agg(w order by w)
    from regexp_split_to_table(
      trim(regexp_replace(
        translate(lower(regexp_replace(p, '\([^)]*\)|\[[^\]]*\]', ' ', 'g')),
                  'àáâãäåāăąçćčďđðèéêëēėęěìíîïīįıłñńňòóôõöøōőŕřśšşșțťùúûüūůűųýÿžźż',
                  'aaaaaaaaacccdddeeeeeeeeiiiiiiilnnnoooooooorrssssttuuuuuuuuyyzzz'),
        '[^[:alpha:]]+', ' ', 'g')), ' ') w
    where w <> ''), ' '), '')
$$;

-- The /in/ slug of a linkedin.com address, lower-cased, query and trailing
-- slash stripped; null for anything else.
create or replace function app.linkedin_key(p text) returns text
language sql immutable strict as $$
  select nullif(substring(lower(p) from 'linkedin\.com/in/([^/?#\s]+)'), '')
$$;

-- p***@example.test; null without an @.
create or replace function app.mask_email(p text) returns text
language sql immutable strict as $$
  select case when position('@' in p) > 1 then lower(left(p, 1) || '***@' || split_part(p, '@', 2)) end
$$;

-- A payload's `custom` as an object, or nothing. A JSON null passes the shape
-- check and coalesce keeps it (a jsonb scalar is not SQL NULL); `{} || null`
-- is then an array, and custom->'zoho'->>'id' finds nothing on it. Internal.
create or replace function app.jsonb_object_or_empty(p jsonb) returns jsonb
language sql immutable as $$
  select case when jsonb_typeof(p) = 'object' then p else '{}'::jsonb end
$$;

-- --------------------------------------------------- columns and indexes
alter table public.candidates
  -- like applications.source_provider: plain text, never an FK to providers
  add column provider text not null default 'manual' check (provider ~ '^[a-z][a-z0-9_]{1,39}$'),
  add column provider_ref text,
  add column source_key text not null default 'added_by_hand' references public.candidate_sources(key),
  add column sourced_by uuid references public.people(id),
  add column current_title text,
  add column current_employer text,
  add column location text,
  add column linkedin_url text,
  add column skills text[] not null default '{}',
  add column summary text,
  add column referred_by text,                 -- Zoho's external referrals have no person row
  add column do_not_contact boolean not null default false,
  add column do_not_contact_reason text,
  add column do_not_contact_at timestamptz,
  add column do_not_contact_by uuid references public.people(id),
  add column contact_later boolean not null default false,
  add column contact_again_after date,
  add column last_activity_at timestamptz not null default now(),
  add column archived_at timestamptz,
  add column phone_key text generated always as (app.phone_key(phone)) stored,
  add column name_key text generated always as (app.name_key(full_name)) stored,
  add column linkedin_key text generated always as (app.linkedin_key(linkedin_url)) stored,
  add constraint candidates_provider_ref_shape check (provider <> 'manual' or provider_ref is null),
  add constraint candidates_never_needs_reason
    check (not do_not_contact or nullif(trim(do_not_contact_reason), '') is not null),
  add constraint candidates_one_contact_rule
    check (not (do_not_contact and contact_later) and (contact_again_after is null or contact_later)),
  add constraint candidates_text_len check (
    length(full_name) between 1 and 200
    and coalesce(length(current_title), 0) <= 200
    and coalesce(length(current_employer), 0) <= 200
    and coalesce(length(location), 0) <= 200
    and coalesce(length(referred_by), 0) <= 200
    and coalesce(length(linkedin_url), 0) <= 300
    and coalesce(length(summary), 0) <= 4000
    and cardinality(skills) <= 100);

create unique index candidates_provider_dedupe
  on public.candidates (provider, provider_ref) where provider_ref is not null;
create index candidates_email_idx on public.candidates (email);
create index candidates_phone_key_idx on public.candidates (phone_key);
create index candidates_name_key_idx on public.candidates (name_key);
create index candidates_linkedin_key_idx on public.candidates (linkedin_key);
create index candidates_activity_idx on public.candidates (last_activity_at desc);
create index applications_candidate_idx on public.applications (candidate_id);

-- How THIS application came to be; source_channel_key / source_provider /
-- provider_ref stay what they are.
alter table public.applications
  add column source_key text references public.candidate_sources(key);

-- -------------------------------------------------------------- backfills
update public.candidates c
   set provider = case when x.careers then 'careers' else c.provider end,
       source_key = case when x.careers then 'careers_page' else c.source_key end,
       last_activity_at = greatest(c.updated_at, x.last_at)
  from (select a.candidate_id,
               bool_or(a.source_channel_key = 'careers') as careers,
               max(greatest(a.received_at, a.updated_at)) as last_at
          from public.applications a group by a.candidate_id) x
 where x.candidate_id = c.id;
-- A candidate without applications keeps its own updated_at as the activity
-- stamp, not the ADD COLUMN default now() (the join above never reaches it).
update public.candidates c
   set last_activity_at = c.updated_at
 where not exists (select 1 from public.applications a where a.candidate_id = c.id);

update public.applications
   set source_key = case source_channel_key
                      when 'careers' then 'careers_page'
                      when 'linkedin' then 'linkedin_ad'
                      when 'indeed' then 'job_board'
                      when 'other_manual' then 'job_board'
                    end
 where source_channel_key in ('careers', 'linkedin', 'indeed', 'other_manual');

-- --------------------------------------------- the visibility rule, rewritten
-- One shared rule, never a parallel scope: the pool is an explicit capability
-- (admins included through has_capability_anywhere), company reviewers see a
-- candidate only through their own company's applications. The 0006 "no
-- applications yet" fallback is gone: a candidate is born through the RPC,
-- never half-made under RLS.
create or replace function app.can_source_candidates() returns boolean
language sql stable security definer set search_path = public as $$
  select app.has_capability_anywhere('candidates.source')
$$;

create or replace function app.can_view_candidate(c uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select c is not null and (app.can_source_candidates()
    or exists (select 1 from public.applications a
               where a.candidate_id = c
                 and app.has_capability(a.company_id, 'candidates.view')))
$$;

create or replace function app.can_edit_candidate(c uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select c is not null and (app.can_source_candidates()
    or exists (select 1 from public.applications a
               where a.candidate_id = c
                 and app.has_capability(a.company_id, 'candidates.review')))
$$;

-- No insert policy: authenticated inserts fail with 42501. `sel` (0006) is untouched.
drop policy write on public.candidates;
create policy upd on public.candidates for update to authenticated
  using (app.can_edit_candidate(id)) with check (app.can_edit_candidate(id));
create policy del on public.candidates for delete to authenticated
  using (app.is_admin());

-- ---------------------------------------------------- flags, guards, touch
-- Two transaction-local flags: app.candidate_rpc ("a trusted writer is
-- running": the public RPCs, the activity touch, the import) and
-- app.candidate_import ("historic rows are being written": the import only).
-- Only the outermost public function and the touch trigger set a flag, and
-- every setter restores the previous value. Every guard predicate is the
-- 0021/0022 idiom, so superuser fixtures, service-role writes and the
-- migration itself pass.

-- The contact rule, in the sentences every picker shows.
create or replace function app.assert_contactable(p_candidate uuid, p_override_wait boolean) returns void
language plpgsql security definer set search_path = public as $$
declare c record;
begin
  select id, full_name, archived_at, do_not_contact, do_not_contact_reason, contact_later, contact_again_after
    into c from public.candidates where id = p_candidate;
  if not found then
    raise exception 'That candidate no longer exists.' using errcode = '22023';
  end if;
  if c.archived_at is not null then
    raise exception '% is archived. Restore the pool record first.', c.full_name;
  end if;
  if c.do_not_contact then
    if app.can_view_candidate(c.id) then
      raise exception '% asked not to be contacted again: %', c.full_name, c.do_not_contact_reason;
    end if;
    raise exception '% asked not to be contacted again.', c.full_name;
  end if;
  if c.contact_later and c.contact_again_after is not null and c.contact_again_after > current_date
     and not coalesce(p_override_wait, false) then
    raise exception '% asked to be contacted after %.', c.full_name, to_char(c.contact_again_after, 'DD Mon YYYY');
  end if;
end $$;

-- The wall holds for a direct PostgREST insert; the RPC already judged the
-- rule with override_wait, the careers page is the person applying
-- themselves (service role), the import writes history.
create or replace function app.guard_application_contact() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null
     or current_setting('app.candidate_rpc', true) is not distinct from 'on'
     or current_setting('app.candidate_import', true) is not distinct from 'on' then
    return new;
  end if;
  perform app.assert_contactable(new.candidate_id, false);
  return new;
end $$;
create trigger t0_guard_contact before insert on public.applications
  for each row execute function app.guard_application_contact();

-- Identity and profile fields stay editable by reviewers where the candidate
-- applied; provenance, the contact rule and the pool fields are locked.
create or replace function app.guard_candidate_fields() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is not null
     and current_setting('app.candidate_rpc', true) is distinct from 'on'
     and current_setting('app.candidate_import', true) is distinct from 'on' then
    if new.provider is distinct from old.provider
       or new.provider_ref is distinct from old.provider_ref
       or new.sourced_by is distinct from old.sourced_by
       or new.created_at is distinct from old.created_at
       or new.last_activity_at is distinct from old.last_activity_at then
      raise exception 'Where a candidate came from is not editable.' using errcode = '42501';
    end if;
    if new.do_not_contact is distinct from old.do_not_contact
       or new.do_not_contact_reason is distinct from old.do_not_contact_reason
       or new.do_not_contact_at is distinct from old.do_not_contact_at
       or new.do_not_contact_by is distinct from old.do_not_contact_by
       or new.contact_later is distinct from old.contact_later
       or new.contact_again_after is distinct from old.contact_again_after then
      raise exception 'Change the contact rule from the candidate''s record.' using errcode = '42501';
    end if;
    if (new.source_key is distinct from old.source_key or new.archived_at is distinct from old.archived_at)
       and not app.can_source_candidates() then
      raise exception 'Changing talent-pool fields needs the "Work the talent pool" capability.' using errcode = '42501';
    end if;
  end if;
  return new;
end $$;
create trigger t2_guard_fields before update on public.candidates
  for each row execute function app.guard_candidate_fields();

-- last_activity_at moves forward, never backwards (an imported 2023
-- application leaves a 2023 activity); the touch is the one writer that sets
-- the flag around its own update and restores the previous value.
create or replace function app.touch_candidate_activity() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_cand uuid; v_at timestamptz; v_prev text;
begin
  if tg_table_name = 'applications' then
    v_cand := new.candidate_id;
    v_at := case when tg_op = 'INSERT' then new.received_at else new.updated_at end;
  elsif tg_table_name = 'application_events' then
    select candidate_id into v_cand from public.applications where id = new.application_id;
    v_at := new.created_at;
  else
    v_cand := new.candidate_id;
    v_at := new.created_at;
  end if;
  if v_cand is null or v_at is null then return new; end if;
  v_prev := current_setting('app.candidate_rpc', true);
  perform set_config('app.candidate_rpc', 'on', true);
  update public.candidates set last_activity_at = v_at
    where id = v_cand and last_activity_at < v_at;
  perform set_config('app.candidate_rpc', coalesce(nullif(v_prev, ''), 'off'), true);
  return new;
end $$;
create trigger t8_touch_candidate
  after insert or update of stage_key, owner_id, next_action, next_action_due on public.applications
  for each row execute function app.touch_candidate_activity();
create trigger t8_touch_candidate after insert on public.application_events
  for each row execute function app.touch_candidate_activity();

-- Audit (there was none). last_activity_at and updated_at are deliberately
-- outside the column list: that is what keeps the touch silent. candidates
-- has no company_id, so these rows land with company_id null and are
-- readable by admins only (as compensation_records, 0018).
create trigger audit after insert or delete or update of
    full_name, email, phone, custom, provider, provider_ref, source_key, sourced_by,
    current_title, current_employer, location, linkedin_url, skills, summary, referred_by,
    do_not_contact, do_not_contact_reason, contact_later, contact_again_after, archived_at
  on public.candidates
  for each row execute function app.audit_redacted('email,phone,phone_key,linkedin_url,linkedin_key,name_key,summary,custom,do_not_contact_reason');

-- ------------------------------------------------ candidate_files and storage
-- The CV on the candidate: readable wherever the person applied and by pool
-- holders. application_files stays for job-specific material.
create table public.candidate_files (
  id uuid primary key default gen_random_uuid(),
  candidate_id uuid not null references public.candidates(id) on delete cascade,
  kind text not null default 'cv' check (kind in ('cv', 'cover_letter', 'portfolio', 'profile', 'other')),
  storage_path text not null unique,
  original_name text not null check (length(original_name) between 1 and 200),
  mime_type text not null,
  size_bytes bigint not null check (size_bytes >= 0),
  uploaded_by uuid references public.people(id),
  extracted_text text,                         -- plain text of a profile capture or a later extraction
  provider text check (provider is null or provider ~ '^[a-z][a-z0-9_]{1,39}$'),
  provider_ref text check (provider_ref is null or provider is not null),
  created_at timestamptz not null default now(),
  constraint candidate_files_path_under_candidate
    check (storage_path like 'candidate/' || candidate_id::text || '/%')
);
create unique index candidate_files_provider_dedupe
  on public.candidate_files (provider, provider_ref) where provider_ref is not null;
create index candidate_files_candidate_idx on public.candidate_files (candidate_id, created_at desc);
create trigger audit after insert or update or delete on public.candidate_files
  for each row execute function app.audit_redacted('extracted_text,original_name');
create trigger t8_touch_candidate after insert on public.candidate_files
  for each row execute function app.touch_candidate_activity();

alter table public.candidate_files enable row level security;
create policy sel on public.candidate_files for select to authenticated
  using (app.can_view_candidate(candidate_id));
-- imported rows (provider, extracted text) come only from the import
create policy ins on public.candidate_files for insert to authenticated
  with check (app.can_edit_candidate(candidate_id) and provider is null and extracted_text is null);
create policy del on public.candidate_files for delete to authenticated
  using (app.can_edit_candidate(candidate_id));
grant select, insert, delete on public.candidate_files to authenticated;
grant all on public.candidate_files to service_role;

-- Objects live at candidate/{candidate_id}/{file_id}.{ext} in the private
-- bucket beside the 0013 application-keyed shape. The 0013 resolver yields
-- null for a first segment that is not a uuid and this one for anything that
-- is not candidate/<uuid>/…, so the two shapes coexist and a malformed name
-- is unreadable and unwritable for a non-admin.
create or replace function app.candidate_object_candidate(object_name text) returns uuid
language sql immutable as $$
  select case
    when split_part(object_name, '/', 1) = 'candidate'
         and split_part(object_name, '/', 2)
             ~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
    then split_part(object_name, '/', 2)::uuid
    else null
  end
$$;

create policy "candidate files: pool read" on storage.objects
  for select to authenticated
  using (bucket_id = 'candidate-files'
         and app.can_view_candidate(app.candidate_object_candidate(name)));
create policy "candidate files: pool upload" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'candidate-files'
              and app.can_edit_candidate(app.candidate_object_candidate(name)));
create policy "candidate files: pool delete" on storage.objects
  for delete to authenticated
  using (bucket_id = 'candidate-files'
         and app.can_edit_candidate(app.candidate_object_candidate(name)));

-- --------------------------------------------------------------- functions

-- Where a pool application is born (internal). No event on creation;
-- received_at records the moment. Seam: the one line where the outreach
-- slice sets an initial sub-status.
create or replace function app.open_application(
  p_candidate uuid, p_job uuid, p_source_key text, p_override_wait boolean
) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  v_cand record;
  v_job record;
  v_id uuid;
  v_constraint text;
begin
  select id, full_name into v_cand from public.candidates where id = p_candidate for update;
  if not found then
    raise exception 'That candidate no longer exists.' using errcode = '22023';
  end if;
  perform app.assert_contactable(p_candidate, p_override_wait);
  select id, company_id, status into v_job from public.jobs where id = p_job;
  if not found then
    raise exception 'That job no longer exists.' using errcode = '22023';
  end if;
  if v_job.status in ('filled', 'closed') then
    raise exception 'This job is %. Reopen it before adding candidates.', v_job.status;
  end if;
  if p_source_key is null
     or not exists (select 1 from public.candidate_sources where key = p_source_key and archived_at is null) then
    raise exception 'Unknown candidate source "%".', p_source_key using errcode = '22023';
  end if;
  begin
    insert into public.applications (job_id, company_id, candidate_id, stage_key, source_key)
      values (p_job, v_job.company_id, p_candidate, 'new', p_source_key)
      returning id into v_id;
  exception when unique_violation then
    get stacked diagnostics v_constraint = constraint_name;
    if v_constraint = 'applications_one_open_per_candidate' then
      raise exception '% already has an open application for this job.', v_cand.full_name;
    end if;
    raise;
  end;
  return v_id;
end $$;

-- One shape check shared by the RPC (raises the first) and the import (collects).
create or replace function app.candidate_payload_problems(p jsonb) returns text[]
language plpgsql stable security definer set search_path = public as $$
declare
  v text[] := '{}';
  v_name text;
  v_email text;
  v_field text;
  v_skills jsonb;
begin
  if p is null or jsonb_typeof(p) <> 'object' then
    return array['Send the candidate as an object.'];
  end if;
  v_name := trim(coalesce(p->>'full_name', ''));
  if length(v_name) < 2 or length(v_name) > 200 then
    v := array_append(v, 'Enter the candidate''s full name (2 to 200 characters).');
  end if;
  v_email := lower(trim(coalesce(p->>'email', '')));
  if v_email <> '' and v_email !~ '^[^@\s]+@[^@\s]+\.[^@\s]+$' then
    v := array_append(v, 'Enter a valid email or leave it empty.');
  end if;
  if length(coalesce(p->>'phone', '')) > 40 then
    v := array_append(v, 'Keep the phone number under 40 characters.');
  end if;
  if length(coalesce(p->>'linkedin_url', '')) > 300 then v := array_append(v, 'LinkedIn URL is too long.'); end if;
  if length(coalesce(p->>'current_title', '')) > 200 then v := array_append(v, 'Current title is too long.'); end if;
  if length(coalesce(p->>'current_employer', '')) > 200 then v := array_append(v, 'Current employer is too long.'); end if;
  if length(coalesce(p->>'location', '')) > 200 then v := array_append(v, 'Location is too long.'); end if;
  if length(coalesce(p->>'referred_by', '')) > 200 then v := array_append(v, 'Referred by is too long.'); end if;
  if length(coalesce(p->>'summary', '')) > 4000 then v := array_append(v, 'Summary is too long.'); end if;
  v_skills := p->'skills';
  if v_skills is not null and jsonb_typeof(v_skills) <> 'null' then
    if jsonb_typeof(v_skills) <> 'array'
       or jsonb_array_length(v_skills) > 100
       or exists (select 1 from jsonb_array_elements(v_skills) e
                  where jsonb_typeof(e) <> 'string' or length(e #>> '{}') > 60) then
      v := array_append(v, 'Skills must be a list of short words.');
    end if;
  end if;
  if p->'custom' is not null and jsonb_typeof(p->'custom') not in ('object', 'null') then
    v := array_append(v, 'custom must be an object.');
  end if;
  if nullif(p->>'source_key', '') is not null
     and not exists (select 1 from public.candidate_sources where key = p->>'source_key' and archived_at is null) then
    v := array_append(v, format('Unknown candidate source "%s".', p->>'source_key'));
  end if;
  return v;
end $$;

-- Skills as stored: trimmed, blanks dropped.
create or replace function app.candidate_skills(p jsonb) returns text[]
language sql immutable as $$
  select coalesce(array(select trim(x) from jsonb_array_elements_text(
           case when jsonb_typeof(p) = 'array' then p else '[]'::jsonb end) x
         where trim(x) <> ''), '{}'::text[])
$$;

-- One row per candidate keeping the strongest match, strongest first then
-- most recent activity, at most 5. Over unarchived rows other than p_exclude.
create or replace function app.candidate_matches(
  p_email text, p_phone text, p_linkedin text, p_name text, p_exclude uuid
) returns table (candidate_id uuid, matched_by text)
language sql stable security definer set search_path = public as $$
  with hits as (
    select c.id, 'email'::text as matched_by, 1 as rank, c.last_activity_at
      from public.candidates c
     where c.archived_at is null and c.id is distinct from p_exclude
       and nullif(trim(p_email), '') is not null and c.email = trim(p_email)::citext
    union all
    select c.id, 'phone', 2, c.last_activity_at
      from public.candidates c
     where c.archived_at is null and c.id is distinct from p_exclude
       and app.phone_key(p_phone) is not null and c.phone_key = app.phone_key(p_phone)
    union all
    select c.id, 'linkedin', 3, c.last_activity_at
      from public.candidates c
     where c.archived_at is null and c.id is distinct from p_exclude
       and app.linkedin_key(p_linkedin) is not null and c.linkedin_key = app.linkedin_key(p_linkedin)
    union all
    select c.id, 'name', 4, c.last_activity_at
      from public.candidates c
     where c.archived_at is null and c.id is distinct from p_exclude
       and app.name_key(p_name) is not null and c.name_key = app.name_key(p_name)
  ), best as (
    select distinct on (id) id, matched_by, rank, last_activity_at from hits order by id, rank
  )
  select id, matched_by from best order by rank, last_activity_at desc limit 5
$$;

-- What a picker may learn about a match: the stored name is the accepted
-- minimum disclosure; nothing about applications the viewer may not see,
-- not even a count. `type CandidateMatch` in candidatePool.ts is this shape.
create or replace function app.candidate_match_hint(p_id uuid, p_matched_by text) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'id', c.id,
    'full_name', c.full_name,
    'match', p_matched_by,
    'visible', v.visible,
    'attachable', v.visible or p_matched_by in ('email', 'phone', 'linkedin'),
    'do_not_contact', c.do_not_contact,
    'contact_later', c.contact_later,
    'contact_again_after', c.contact_again_after,
    'email', case when v.visible then c.email::text
                  when p_matched_by = 'email' then app.mask_email(c.email::text) end,
    'phone', case when v.visible then c.phone end,
    'linkedin_url', case when v.visible then c.linkedin_url end,
    'current_title', case when v.visible then c.current_title end,
    'current_employer', case when v.visible then c.current_employer end,
    'last_activity_at', case when v.visible then c.last_activity_at end,
    'applications', case when v.visible then coalesce((
        select jsonb_agg(jsonb_build_object(
                 'id', a.id, 'job_title', j.title, 'company_name', co.name,
                 'stage_key', a.stage_key, 'received_at', a.received_at)
               order by a.received_at desc)
        from (select * from public.applications a
               where a.candidate_id = c.id and app.has_capability(a.company_id, 'candidates.view')
               order by a.received_at desc limit 5) a
        join public.jobs j on j.id = a.job_id
        join public.companies co on co.id = a.company_id), '[]'::jsonb)
      else '[]'::jsonb end)
  from public.candidates c, lateral (select app.can_view_candidate(c.id) as visible) v
  where c.id = p_id
$$;

-- The one door that creates a candidate from the app: `manual` today,
-- `linkedin_recruiter` / `csv` tomorrow with a ref per row. Matches are
-- reported, never merged, never blocking.
create or replace function public.upsert_sourced_candidate(p_provider text, p_ref text, p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_ref text := nullif(trim(coalesce(p_ref, '')), '');
  v_job_id uuid;
  v_job_company uuid;
  v_company_name text;
  v_cand public.candidates;
  v_id uuid;
  v_action text;
  v_source_key text;
  v_problems text[];
  v_matches jsonb;
  v_dups jsonb;
  v_app uuid;
  v_prev text;
  v_attach uuid;
  v_ignore boolean := coalesce((p->>'ignore_matches')::boolean, false);
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  if p_provider is null or p_provider !~ '^[a-z][a-z0-9_]{1,39}$' then
    raise exception 'Name the provider, e.g. manual.' using errcode = '22023';
  end if;
  if p_provider = 'manual' and v_ref is not null then
    raise exception 'Manual records carry no provider reference.' using errcode = '22023';
  end if;
  if v_ref is not null and not app.can_source_candidates() then
    raise exception 'Importing provider records needs the "Work the talent pool" capability.' using errcode = '42501';
  end if;
  if p is null or jsonb_typeof(p) <> 'object' then
    raise exception 'Send the candidate as an object.' using errcode = '22023';
  end if;
  if nullif(p->>'job_id', '') is not null then
    select j.id, j.company_id, c.name into v_job_id, v_job_company, v_company_name
      from public.jobs j join public.companies c on c.id = j.company_id
      where j.id = (p->>'job_id')::uuid;
    if not found then
      raise exception 'That job no longer exists.' using errcode = '22023';
    end if;
    if not app.has_capability(v_job_company, 'candidates.review') then
      raise exception 'Adding a candidate to this job needs the "Record interview feedback" capability in %.', v_company_name
        using errcode = '42501';
    end if;
  elsif not app.can_source_candidates() then
    raise exception 'Adding to the talent pool needs the "Work the talent pool" capability.' using errcode = '42501';
  end if;
  v_attach := nullif(p->>'attach_to', '')::uuid;
  if v_attach is not null and (v_ignore or v_ref is not null) then
    raise exception 'Choose one: attach or create.' using errcode = '22023';
  end if;
  if v_attach is null then
    v_problems := app.candidate_payload_problems(p);
    if cardinality(v_problems) > 0 then
      raise exception '%', v_problems[1] using errcode = '22023';
    end if;
  end if;

  v_prev := current_setting('app.candidate_rpc', true);
  perform set_config('app.candidate_rpc', 'on', true);

  if v_ref is not null then
    -- A: provider-keyed. Present keys overwrite; absent keys leave the column
    -- alone; created_at, the contact rule and sourced_by are never touched.
    select * into v_cand from public.candidates
      where provider = p_provider and provider_ref = v_ref for update;
    if found then
      update public.candidates set
        full_name = case when p ? 'full_name' then trim(p->>'full_name') else full_name end,
        email = case when p ? 'email' then nullif(trim(p->>'email'), '')::citext else email end,
        phone = case when p ? 'phone' then nullif(trim(p->>'phone'), '') else phone end,
        linkedin_url = case when p ? 'linkedin_url' then nullif(trim(p->>'linkedin_url'), '') else linkedin_url end,
        current_title = case when p ? 'current_title' then nullif(trim(p->>'current_title'), '') else current_title end,
        current_employer = case when p ? 'current_employer' then nullif(trim(p->>'current_employer'), '') else current_employer end,
        location = case when p ? 'location' then nullif(trim(p->>'location'), '') else location end,
        skills = case when p ? 'skills' then app.candidate_skills(p->'skills') else skills end,
        summary = case when p ? 'summary' then nullif(trim(p->>'summary'), '') else summary end,
        referred_by = case when p ? 'referred_by' then nullif(trim(p->>'referred_by'), '') else referred_by end,
        source_key = case when nullif(p->>'source_key', '') is not null then p->>'source_key' else source_key end,
        custom = custom || app.jsonb_object_or_empty(p->'custom')
        where id = v_cand.id
        returning id, source_key into v_id, v_source_key;
      v_action := 'updated';
    else
      insert into public.candidates
        (provider, provider_ref, full_name, email, phone, linkedin_url, current_title, current_employer,
         location, skills, summary, referred_by, source_key, sourced_by, custom, created_at, last_activity_at)
      select p_provider, v_ref, trim(p->>'full_name'), nullif(trim(p->>'email'), '')::citext,
             nullif(trim(p->>'phone'), ''), nullif(trim(p->>'linkedin_url'), ''),
             nullif(trim(p->>'current_title'), ''), nullif(trim(p->>'current_employer'), ''),
             nullif(trim(p->>'location'), ''), app.candidate_skills(p->'skills'),
             nullif(trim(p->>'summary'), ''), nullif(trim(p->>'referred_by'), ''),
             coalesce(nullif(p->>'source_key', ''), 'imported'),
             coalesce(nullif(p->>'sourced_by', '')::uuid, v_me),
             app.jsonb_object_or_empty(p->'custom'),
             c.created_at, coalesce(nullif(p->>'last_activity_at', '')::timestamptz, c.created_at)
      from (select coalesce(nullif(p->>'created_at', '')::timestamptz, now()) as created_at) c
      returning id, source_key into v_id, v_source_key;
      v_action := 'created';
    end if;
    select coalesce(jsonb_agg(app.candidate_match_hint(m.candidate_id, m.matched_by)), '[]'::jsonb) into v_dups
      from public.candidates c
      cross join lateral app.candidate_matches(c.email::text, c.phone, c.linkedin_url, c.full_name, c.id) m
      where c.id = v_id;
  elsif v_attach is not null then
    -- B: attach to an existing record; no identity write.
    select * into v_cand from public.candidates where id = v_attach for update;
    if not found then
      raise exception 'That candidate no longer exists.' using errcode = '22023';
    end if;
    if v_cand.archived_at is not null then
      raise exception '% is archived. Restore the pool record first.', v_cand.full_name;
    end if;
    if not (app.can_view_candidate(v_cand.id)
            or (nullif(trim(p->>'email'), '') is not null and v_cand.email = trim(p->>'email')::citext)
            or (app.phone_key(p->>'phone') is not null and app.phone_key(p->>'phone') = v_cand.phone_key)
            or (app.linkedin_key(p->>'linkedin_url') is not null and app.linkedin_key(p->>'linkedin_url') = v_cand.linkedin_key)) then
      raise exception 'You cannot attach to that candidate.' using errcode = '42501';
    end if;
    v_id := v_cand.id;
    v_source_key := v_cand.source_key;
    v_action := 'attached';
  else
    -- C: manual. A match is offered without exposing the record and nothing
    -- is written unless the caller says to ignore the matches.
    select coalesce(jsonb_agg(app.candidate_match_hint(m.candidate_id, m.matched_by)), '[]'::jsonb) into v_matches
      from app.candidate_matches(p->>'email', p->>'phone', p->>'linkedin_url', p->>'full_name', null) m;
    if jsonb_array_length(v_matches) > 0 and not v_ignore then
      perform set_config('app.candidate_rpc', coalesce(nullif(v_prev, ''), 'off'), true);
      return jsonb_build_object('action', 'matches', 'id', null, 'application_id', null,
                                'matches', v_matches, 'possible_duplicates', '[]'::jsonb);
    end if;
    insert into public.candidates
      (provider, provider_ref, full_name, email, phone, linkedin_url, current_title, current_employer,
       location, skills, summary, referred_by, source_key, sourced_by, custom)
    values ('manual', null, trim(p->>'full_name'), nullif(trim(p->>'email'), '')::citext,
            nullif(trim(p->>'phone'), ''), nullif(trim(p->>'linkedin_url'), ''),
            nullif(trim(p->>'current_title'), ''), nullif(trim(p->>'current_employer'), ''),
            nullif(trim(p->>'location'), ''), app.candidate_skills(p->'skills'),
            nullif(trim(p->>'summary'), ''), nullif(trim(p->>'referred_by'), ''),
            coalesce(nullif(p->>'source_key', ''), 'added_by_hand'),
            case when app.is_admin() then coalesce(nullif(p->>'sourced_by', '')::uuid, v_me) else v_me end,
            app.jsonb_object_or_empty(p->'custom'))
    returning id, source_key into v_id, v_source_key;
    v_action := 'created';
  end if;

  -- D: straight onto the job.
  if v_job_id is not null then
    v_app := app.open_application(v_id, v_job_id,
      coalesce(nullif(p->>'application_source_key', ''),
               case when v_action = 'attached' then 'added_by_hand' else v_source_key end),
      coalesce((p->>'override_wait')::boolean, false));
  end if;

  perform set_config('app.candidate_rpc', coalesce(nullif(v_prev, ''), 'off'), true);
  return jsonb_build_object('action', v_action, 'id', v_id, 'application_id', v_app,
                            'matches', coalesce(v_matches, '[]'::jsonb),
                            'possible_duplicates', coalesce(v_dups, '[]'::jsonb));
end $$;

-- "Source from pool" and the record's Add to job.
create or replace function public.add_candidate_to_job(
  p_candidate_id uuid, p_job_id uuid, p_source_key text default 'head_hunt', p_override_wait boolean default false
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_job record;
  v_prev text;
  v_app uuid;
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  select j.id, j.company_id, c.name as company_name into v_job
    from public.jobs j join public.companies c on c.id = j.company_id where j.id = p_job_id;
  if not found then
    raise exception 'That job no longer exists.' using errcode = '22023';
  end if;
  if not app.has_capability(v_job.company_id, 'candidates.review') then
    raise exception 'Adding a candidate to this job needs the "Record interview feedback" capability in %.', v_job.company_name
      using errcode = '42501';
  end if;
  if not app.can_view_candidate(p_candidate_id) then
    raise exception 'You cannot see that candidate.' using errcode = '42501';
  end if;
  v_prev := current_setting('app.candidate_rpc', true);
  perform set_config('app.candidate_rpc', 'on', true);
  v_app := app.open_application(p_candidate_id, p_job_id, coalesce(nullif(p_source_key, ''), 'head_hunt'),
                                coalesce(p_override_wait, false));
  perform set_config('app.candidate_rpc', coalesce(nullif(v_prev, ''), 'off'), true);
  return jsonb_build_object('application_id', v_app);
end $$;

-- The contact rule: ok / later / never, on the record, by pool holders only.
create or replace function public.set_contact_rule(p_candidate_id uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_rule text := p->>'rule';
  v_reason text := nullif(trim(coalesce(p->>'reason', '')), '');
  v_after date;
  v_prev text;
  v_row record;
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  if not app.can_source_candidates() then
    raise exception 'Changing the contact rule needs the "Work the talent pool" capability.' using errcode = '42501';
  end if;
  perform 1 from public.candidates where id = p_candidate_id for update;
  if not found then
    raise exception 'That candidate no longer exists.' using errcode = '22023';
  end if;
  if v_rule is null or v_rule not in ('ok', 'later', 'never') then
    raise exception 'Pick a contact rule.' using errcode = '22023';
  end if;
  if v_rule = 'never' and v_reason is null then
    raise exception 'Say why this person must not be contacted again.' using errcode = '22023';
  end if;
  if v_rule = 'later' then
    v_after := nullif(p->>'contact_again_after', '')::date;
    if v_after is not null and v_after < current_date then
      raise exception 'Pick a date from today on.' using errcode = '22023';
    end if;
  end if;

  v_prev := current_setting('app.candidate_rpc', true);
  perform set_config('app.candidate_rpc', 'on', true);
  if v_rule = 'never' then
    update public.candidates set
      do_not_contact = true, do_not_contact_reason = v_reason, do_not_contact_at = now(), do_not_contact_by = v_me,
      contact_later = false, contact_again_after = null
      where id = p_candidate_id;
  elsif v_rule = 'later' then
    update public.candidates set
      do_not_contact = false, do_not_contact_reason = null, do_not_contact_at = null, do_not_contact_by = null,
      contact_later = true, contact_again_after = v_after
      where id = p_candidate_id;
  else
    update public.candidates set
      do_not_contact = false, do_not_contact_reason = null, do_not_contact_at = null, do_not_contact_by = null,
      contact_later = false, contact_again_after = null
      where id = p_candidate_id;
  end if;
  perform set_config('app.candidate_rpc', coalesce(nullif(v_prev, ''), 'off'), true);

  select do_not_contact, do_not_contact_reason, do_not_contact_at, do_not_contact_by, contact_later, contact_again_after
    into v_row from public.candidates where id = p_candidate_id;
  return to_jsonb(v_row);
end $$;

-- The pool, for pool holders: the gate already means "sees the whole pool";
-- the applications sub-list is scoped explicitly.
create or replace function public.search_candidates(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_q text := nullif(trim(coalesce(p->>'q', '')), '');
  v_like text;
  v_name_key text;
  v_phone_key text;
  v_linkedin_key text;
  v_source text := nullif(p->>'source_key', '');
  v_contact text := coalesce(nullif(p->>'contact', ''), 'any');
  v_activity text := coalesce(nullif(p->>'activity', ''), 'any');
  v_company uuid := nullif(p->>'company_id', '')::uuid;
  v_archived boolean := coalesce((p->>'include_archived')::boolean, false);
  v_limit int := least(greatest(coalesce((p->>'limit')::int, 50), 1), 100);
  v_offset int := greatest(coalesce((p->>'offset')::int, 0), 0);
  v_total int;
  v_rows jsonb;
begin
  if app.current_person_id() is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  if not app.can_source_candidates() then
    raise exception 'The talent pool needs the "Work the talent pool" capability.' using errcode = '42501';
  end if;
  if v_contact not in ('any', 'ok', 'do_not_contact', 'wait') then
    raise exception 'Unknown contact filter "%".', v_contact using errcode = '22023';
  end if;
  if v_activity not in ('any', '90d', '1y', 'older') then
    raise exception 'Unknown activity filter "%".', v_activity using errcode = '22023';
  end if;
  if v_q is not null then
    v_like := '%' || replace(replace(replace(v_q, '\', '\\'), '%', '\%'), '_', '\_') || '%';
    v_name_key := app.name_key(v_q);
    v_phone_key := app.phone_key(v_q);
    v_linkedin_key := app.linkedin_key(v_q);
  end if;

  with f as (
    select c.*
    from public.candidates c
    where (v_archived or c.archived_at is null)
      and (v_q is null
           or (v_name_key is not null and c.name_key like '%' || v_name_key || '%')
           or c.email::text ilike v_like
           or (v_phone_key is not null and c.phone_key = v_phone_key)
           or (v_linkedin_key is not null and c.linkedin_key = v_linkedin_key)
           or c.current_title ilike v_like
           or c.current_employer ilike v_like
           or exists (select 1 from unnest(c.skills) s where s ilike v_like))
      and (v_source is null or c.source_key = v_source)
      and (v_contact = 'any'
           or (v_contact = 'ok' and not c.do_not_contact and not c.contact_later)
           or (v_contact = 'do_not_contact' and c.do_not_contact)
           or (v_contact = 'wait' and c.contact_later))
      and (v_activity = 'any'
           or (v_activity = '90d' and c.last_activity_at >= now() - interval '90 days')
           or (v_activity = '1y' and c.last_activity_at >= now() - interval '1 year')
           or (v_activity = 'older' and c.last_activity_at < now() - interval '1 year'))
      and (v_company is null or exists (
             select 1 from public.applications a
             where a.candidate_id = c.id and a.company_id = v_company
               and app.has_capability(a.company_id, 'candidates.view')))
  ), page as (
    select * from f order by last_activity_at desc, full_name limit v_limit offset v_offset
  )
  select (select count(*) from f),
         coalesce((select jsonb_agg(jsonb_build_object(
             'id', pg.id, 'full_name', pg.full_name, 'email', pg.email, 'phone', pg.phone,
             'current_title', pg.current_title, 'current_employer', pg.current_employer,
             'location', pg.location, 'skills', to_jsonb(pg.skills),
             'source_key', pg.source_key,
             'source_label', (select cs.label from public.candidate_sources cs where cs.key = pg.source_key),
             'provider', pg.provider,
             'do_not_contact', pg.do_not_contact, 'contact_later', pg.contact_later,
             'contact_again_after', pg.contact_again_after,
             'last_activity_at', pg.last_activity_at, 'archived_at', pg.archived_at,
             'files_count', (select count(*) from public.candidate_files cf where cf.candidate_id = pg.id),
             'applications', coalesce((
               select jsonb_agg(jsonb_build_object(
                        'id', a.id, 'job_id', a.job_id, 'job_title', j.title,
                        'company_id', a.company_id, 'company_name', co.name,
                        'stage_key', a.stage_key, 'received_at', a.received_at)
                      order by a.received_at desc)
               from (select * from public.applications a
                      where a.candidate_id = pg.id and app.has_capability(a.company_id, 'candidates.view')
                      order by a.received_at desc limit 3) a
               join public.jobs j on j.id = a.job_id
               join public.companies co on co.id = a.company_id), '[]'::jsonb))
           order by pg.last_activity_at desc, pg.full_name) from page pg), '[]'::jsonb)
    into v_total, v_rows;
  return jsonb_build_object('total', v_total, 'rows', v_rows);
end $$;

-- HR confirms (or declines) the employee record for an imported hire. Never
-- creates a person (blueprint §5).
create or replace function public.link_hired_application(p_application_id uuid, p_person_id uuid default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_app record;
  v_person record;
  v_period uuid;
  v_company text;
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  select * into v_app from public.applications where id = p_application_id for update;
  if not found then
    raise exception 'That application no longer exists.' using errcode = '22023';
  end if;
  if not app.has_capability(v_app.company_id, 'employment.edit') then
    raise exception 'Linking a hire needs the "Edit employment information" capability in this company.'
      using errcode = '42501';
  end if;
  if v_app.stage_key <> 'hired' then
    raise exception 'Only hired applications can be linked to an employee record.' using errcode = '22023';
  end if;
  if v_app.employment_period_id is not null then
    raise exception 'This application is already linked to an employee record.' using errcode = '22023';
  end if;
  if p_person_id is null then
    update public.applications
      set custom = jsonb_set(custom, '{zoho}', app.jsonb_object_or_empty(custom->'zoho')
            || jsonb_build_object('proposed_person', null, 'link_declined_by', v_me, 'link_declined_at', now()))
      where id = p_application_id;
    return jsonb_build_object('linked', false);
  end if;
  select id, full_name into v_person from public.people where id = p_person_id;
  if not found then
    raise exception 'That person no longer exists.' using errcode = '22023';
  end if;
  select ep.id into v_period from public.employment_periods ep
    where ep.person_id = p_person_id and ep.company_id = v_app.company_id
    order by abs(ep.start_date - coalesce((v_app.custom #>> '{zoho,hired_date}')::date, v_app.received_at::date)),
             ep.start_date desc
    limit 1;
  if v_period is null then
    select name into v_company from public.companies where id = v_app.company_id;
    raise exception '% has no employment record in %.', v_person.full_name, v_company using errcode = '22023';
  end if;
  begin
    update public.applications set employment_period_id = v_period where id = p_application_id;
  exception when unique_violation then
    raise exception 'That employment record is already linked to another application.' using errcode = '22023';
  end;
  insert into public.application_events (application_id, kind, body, actor_id)
    values (p_application_id, 'note',
            format('Linked to the employee record of %s by %s.', v_person.full_name, app.person_name(v_me)), v_me);
  return jsonb_build_object('linked', true, 'employment_period_id', v_period, 'person_id', p_person_id);
end $$;

-- The Zoho Recruit import: the shape and discipline of import_field_notebook
-- (0028). Pass 1 decides every row and builds verdicts; p_commit = false
-- returns the report without writing; p_commit = true writes all or nothing.
create or replace function public.import_zoho_recruit(p_payload jsonb, p_commit boolean default false)
returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_prev_rpc text;
  v_prev_import text;
  v_row jsonb;
  v_m record;
  v_problems text[];
  v_refused int := 0;
  v_verdicts jsonb := '[]'::jsonb;
  v_assumptions jsonb := '[]'::jsonb;
  v_hires jsonb := '[]'::jsonb;
  v_dups jsonb := '[]'::jsonb;
  v_counts jsonb;
  -- resolved lookups (jsonb dictionaries like 0028)
  v_company_by_code jsonb := '{}'::jsonb;  -- short code -> company uuid
  v_company_name jsonb := '{}'::jsonb;     -- company uuid -> name
  v_person_by_email jsonb := '{}'::jsonb;  -- lower work email -> person uuid
  v_user_person jsonb := '{}'::jsonb;      -- zoho user id -> person uuid
  v_user_name jsonb := '{}'::jsonb;        -- zoho user id -> name
  v_users_resolved jsonb := '[]'::jsonb;
  v_users_unresolved jsonb := '[]'::jsonb;
  -- per-row decisions (job / candidate / application / open_pair) live in
  -- the temp table pg_temp.zoho_import_rows: a jsonb dictionary grows
  -- quadratically over thousands of rows, a keyed table does not
  v_depts jsonb := '{}'::jsonb;            -- department -> company code
  v_info jsonb;
  v_cinfo jsonb;
  v_id uuid;
  v_existing uuid;
  v_company uuid;
  v_person uuid;
  v_email text;
  v_code text;
  v_stage text;
  v_final text;
  v_stale boolean;
  v_close timestamptz;
  v_close_assumed boolean;
  v_proposal jsonb;
  v_n int;
  v_jobs_created int := 0;
  v_jobs_skipped int := 0;
  v_cands_created int := 0;
  v_cands_skipped int := 0;
  v_apps_created int := 0;
  v_apps_skipped int := 0;
  v_stale_closed int := 0;
  v_events_planned int := 0;
  v_events_created int := 0;
  v_notes_planned int := 0;
  v_notes_created int := 0;
  v_dnc int := 0;
  v_later int := 0;
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  if not app.is_admin() then
    raise exception 'Importing from Zoho Recruit needs platform admin access.' using errcode = '42501';
  end if;
  if p_payload is null or jsonb_typeof(p_payload) <> 'object'
     or jsonb_typeof(p_payload->'candidates') <> 'array' then
    raise exception 'The payload needs a "candidates" array.' using errcode = '22023';
  end if;

  if to_regclass('pg_temp.zoho_import_rows') is not null then
    drop table pg_temp.zoho_import_rows;
  end if;
  create temp table zoho_import_rows (
    kind text not null, ref text not null, info jsonb not null, primary key (kind, ref)
  ) on commit drop;

  v_assumptions := v_assumptions || jsonb_build_object('kind', 'timezone',
    'timezone_assumed', coalesce(p_payload->>'timezone_assumed', 'Europe/Skopje'));

  -- ------------------------------------------------------------ companies
  for v_code in
    select distinct j->>'company_code' from jsonb_array_elements(coalesce(p_payload->'jobs', '[]'::jsonb)) j
    where j->>'company_code' is not null
  loop
    select id into v_company from public.companies where short_code = v_code and archived_at is null;
    if v_company is not null then
      v_company_by_code := v_company_by_code || jsonb_build_object(v_code, v_company);
      v_company_name := v_company_name || jsonb_build_object(v_company::text,
        (select name from public.companies where id = v_company));
    end if;
  end loop;

  -- ---------------------------------------------------------------- users
  -- Zoho users → people by work email; the generic hr@ / admin@ accounts
  -- never map; unresolved users are kept by name.
  select coalesce(jsonb_object_agg(lower(work_email::text), id), '{}'::jsonb) into v_person_by_email
    from public.people where work_email is not null and archived_at is null;
  for v_row in select * from jsonb_array_elements(coalesce(p_payload->'users', '[]'::jsonb)) loop
    v_email := lower(trim(coalesce(v_row->>'email', '')));
    v_person := case when v_email <> '' and v_email not like 'hr@%' and v_email not like 'admin@%'
                     then (v_person_by_email->>v_email)::uuid end;
    v_user_name := v_user_name || jsonb_build_object(v_row->>'zoho_id',
      coalesce(nullif(trim(coalesce(v_row->>'name', '')), ''), v_email));
    if v_person is not null then
      v_user_person := v_user_person || jsonb_build_object(v_row->>'zoho_id', v_person);
      v_users_resolved := v_users_resolved || jsonb_build_object('zoho_id', v_row->>'zoho_id',
        'email', v_email, 'name', v_row->>'name', 'person_id', v_person);
    else
      v_users_unresolved := v_users_unresolved || jsonb_build_object('zoho_id', v_row->>'zoho_id',
        'email', v_email, 'name', v_row->>'name');
    end if;
  end loop;

  -- ----------------------------------------------------------------- jobs
  for v_row in select * from jsonb_array_elements(coalesce(p_payload->'jobs', '[]'::jsonb)) loop
    v_problems := '{}';
    if nullif(v_row->>'zoho_id', '') is null then v_problems := array_append(v_problems, 'no zoho_id'); end if;
    if length(trim(coalesce(v_row->>'title', ''))) not between 2 and 200 then
      v_problems := array_append(v_problems, 'the title must be 2 to 200 characters');
    end if;
    if coalesce(v_row->>'status', '') not in ('draft', 'ready', 'open', 'on_hold', 'filled', 'closed') then
      v_problems := array_append(v_problems, format('status "%s" is not a job status', v_row->>'status'));
    end if;
    v_company := (v_company_by_code->>coalesce(v_row->>'company_code', ''))::uuid;
    if v_company is null then
      v_problems := array_append(v_problems, format('no company with short code %s', coalesce(v_row->>'company_code', '(none)')));
    end if;
    if exists (select 1 from pg_temp.zoho_import_rows where kind = 'job' and ref = v_row->>'zoho_id') then
      v_problems := array_append(v_problems, 'zoho_id appears twice in the extract');
    end if;
    if cardinality(v_problems) > 0 then
      v_verdicts := v_verdicts || jsonb_build_object('kind', 'job', 'ref', v_row->>'zoho_id', 'problems', to_jsonb(v_problems));
      v_refused := v_refused + 1;
      continue;
    end if;
    select id into v_id from public.jobs where custom->'zoho'->>'id' = v_row->>'zoho_id';
    if v_id is not null then
      v_jobs_skipped := v_jobs_skipped + 1;
      v_info := jsonb_build_object('id', v_id, 'create', false);
    else
      v_id := gen_random_uuid();   -- the dry run resolves applications against it; the commit inserts it
      v_jobs_created := v_jobs_created + 1;
      v_info := jsonb_build_object('id', v_id, 'create', true);
      if v_row->>'status' in ('filled', 'closed') and nullif(v_row->>'date_closed', '') is null then
        v_assumptions := v_assumptions || jsonb_build_object('kind', 'close_date_assumed', 'job', v_row->>'zoho_id',
          'title', v_row->>'title', 'close_date', v_row->>'modified_at');
      end if;
    end if;
    insert into pg_temp.zoho_import_rows values ('job', v_row->>'zoho_id', v_info || jsonb_build_object(
      'title', trim(v_row->>'title'), 'company_id', v_company, 'status', v_row->>'status',
      'date_closed', v_row->>'date_closed', 'modified_at', v_row->>'modified_at'));
    if v_row->'custom'->'zoho'->>'department' is not null
       and not v_depts ? (v_row->'custom'->'zoho'->>'department') then
      v_depts := v_depts || jsonb_build_object(v_row->'custom'->'zoho'->>'department', v_row->>'company_code');
    end if;
  end loop;
  for v_row in select jsonb_build_object('department', key, 'company_code', value) from jsonb_each_text(v_depts) loop
    v_assumptions := v_assumptions || (jsonb_build_object('kind', 'department') || v_row);
  end loop;

  -- ------------------------------------------------------------ candidates
  for v_row in select * from jsonb_array_elements(p_payload->'candidates') loop
    v_problems := app.candidate_payload_problems(v_row);
    if nullif(v_row->>'zoho_id', '') is null then v_problems := array_append(v_problems, 'no zoho_id'); end if;
    if coalesce((v_row->>'do_not_contact')::boolean, false)
       and nullif(trim(coalesce(v_row->>'do_not_contact_reason', '')), '') is null then
      v_problems := array_append(v_problems, 'do_not_contact needs a reason');
    end if;
    if coalesce((v_row->>'do_not_contact')::boolean, false) and coalesce((v_row->>'contact_later')::boolean, false) then
      v_problems := array_append(v_problems, 'do_not_contact and contact_later cannot both be set');
    end if;
    if exists (select 1 from pg_temp.zoho_import_rows where kind = 'candidate' and ref = v_row->>'zoho_id') then
      v_problems := array_append(v_problems, 'zoho_id appears twice in the extract');
    end if;
    if cardinality(v_problems) > 0 then
      v_verdicts := v_verdicts || jsonb_build_object('kind', 'candidate', 'ref', v_row->>'zoho_id', 'problems', to_jsonb(v_problems));
      v_refused := v_refused + 1;
      continue;
    end if;
    select id into v_id from public.candidates where provider = 'zoho_recruit' and provider_ref = v_row->>'zoho_id';
    if v_id is not null then
      v_cands_skipped := v_cands_skipped + 1;
      v_info := jsonb_build_object('id', v_id, 'create', false);
    else
      v_id := gen_random_uuid();
      v_cands_created := v_cands_created + 1;
      v_info := jsonb_build_object('id', v_id, 'create', true);
      if coalesce((v_row->>'do_not_contact')::boolean, false) then v_dnc := v_dnc + 1; end if;
      if coalesce((v_row->>'contact_later')::boolean, false) then v_later := v_later + 1; end if;
      if v_row->>'do_not_contact_reason' like 'Zoho Recruit: NEVER%' then
        v_assumptions := v_assumptions || jsonb_build_object('kind', 'synthesised_reason',
          'candidate', v_row->>'zoho_id', 'full_name', v_row->>'full_name', 'reason', v_row->>'do_not_contact_reason');
      end if;
      -- Possible duplicates against non-Zoho rows: reported, never merged.
      for v_m in
        select m.candidate_id, m.matched_by, c.full_name
        from app.candidate_matches(v_row->>'email', v_row->>'phone', v_row->>'linkedin_url', v_row->>'full_name', null) m
        join public.candidates c on c.id = m.candidate_id
        where c.provider <> 'zoho_recruit'
      loop
        v_dups := v_dups || jsonb_build_object('zoho_ref', v_row->>'zoho_id', 'full_name', trim(v_row->>'full_name'),
          'existing_id', v_m.candidate_id, 'existing_name', v_m.full_name, 'match', v_m.matched_by);
      end loop;
    end if;
    insert into pg_temp.zoho_import_rows values ('candidate', v_row->>'zoho_id', v_info || jsonb_build_object(
      'full_name', trim(v_row->>'full_name'), 'source_key', coalesce(nullif(v_row->>'source_key', ''), 'imported'),
      'email', nullif(trim(coalesce(v_row->>'email', '')), ''), 'phone', nullif(trim(coalesce(v_row->>'phone', '')), '')));
  end loop;

  -- ---------------------------------------------------------- applications
  for v_row in select * from jsonb_array_elements(coalesce(p_payload->'applications', '[]'::jsonb)) loop
    v_problems := '{}';
    if nullif(v_row->>'zoho_id', '') is null then v_problems := array_append(v_problems, 'no zoho_id'); end if;
    if exists (select 1 from pg_temp.zoho_import_rows where kind = 'application' and ref = v_row->>'zoho_id') then
      v_problems := array_append(v_problems, 'zoho_id appears twice in the extract');
    end if;
    select info into v_cinfo from pg_temp.zoho_import_rows
      where kind = 'candidate' and ref = coalesce(v_row->>'candidate_zoho_id', '');
    if v_cinfo is null then
      v_problems := array_append(v_problems, format('candidate %s is not in the extract', coalesce(v_row->>'candidate_zoho_id', '(none)')));
    end if;
    select info into v_info from pg_temp.zoho_import_rows
      where kind = 'job' and ref = coalesce(v_row->>'job_zoho_id', '');
    if v_info is null then
      v_problems := array_append(v_problems, format('job %s is not in the extract', coalesce(v_row->>'job_zoho_id', '(none)')));
    end if;
    v_stage := v_row->>'stage_key';
    if v_stage is null or not exists (select 1 from public.application_stages where key = v_stage) then
      v_problems := array_append(v_problems, format('stage "%s" is unknown', coalesce(v_stage, '(none)')));
    end if;
    if cardinality(v_problems) > 0 then
      v_verdicts := v_verdicts || jsonb_build_object('kind', 'application', 'ref', v_row->>'zoho_id', 'problems', to_jsonb(v_problems));
      v_refused := v_refused + 1;
      continue;
    end if;
    v_stale := coalesce((v_row->>'stale_closed')::boolean, false);
    v_final := case when v_stale then 'withdrawn' else v_stage end;
    v_close := coalesce(nullif(v_row->>'close_date', '')::timestamptz, nullif(v_info->>'date_closed', '')::timestamptz,
                        nullif(v_info->>'modified_at', '')::timestamptz, nullif(v_row->>'modified_at', '')::timestamptz);
    v_close_assumed := coalesce((v_row->>'close_date_assumed')::boolean,
                                nullif(v_row->>'close_date', '') is null and nullif(v_info->>'date_closed', '') is null);
    if v_final not in ('hired', 'rejected', 'withdrawn') then
      v_code := (v_info->>'id') || '|' || (v_cinfo->>'id');
      if exists (select 1 from pg_temp.zoho_import_rows where kind = 'open_pair' and ref = v_code) then
        v_verdicts := v_verdicts || jsonb_build_object('kind', 'application', 'ref', v_row->>'zoho_id',
          'problems', to_jsonb(array[format('a second open application for the same candidate and job (see %s)',
            (select info->>'application' from pg_temp.zoho_import_rows where kind = 'open_pair' and ref = v_code))]));
        v_refused := v_refused + 1;
        continue;
      end if;
      insert into pg_temp.zoho_import_rows values ('open_pair', v_code, jsonb_build_object('application', v_row->>'zoho_id'));
    end if;
    select id into v_id from public.applications
      where job_id = (v_info->>'id')::uuid and source_provider = 'zoho_recruit' and provider_ref = v_row->>'zoho_id';
    v_proposal := null;
    if v_id is not null then
      v_apps_skipped := v_apps_skipped + 1;
      insert into pg_temp.zoho_import_rows values ('application', v_row->>'zoho_id', jsonb_build_object('id', v_id, 'create', false));
      continue;
    end if;
    if v_final not in ('hired', 'rejected', 'withdrawn') then
      -- An open application from another source (HR added the same person to
      -- an imported job by hand between runs) is refused here, by the
      -- applications_one_open_per_candidate rule, not as a wrapped unique
      -- violation in pass 2. A new candidate or job carries a placeholder id
      -- and matches nothing.
      select id into v_existing from public.applications
        where job_id = (v_info->>'id')::uuid and candidate_id = (v_cinfo->>'id')::uuid
          and stage_key not in ('hired', 'rejected', 'withdrawn');
      if v_existing is not null then
        v_verdicts := v_verdicts || jsonb_build_object('kind', 'application', 'ref', v_row->>'zoho_id',
          'problems', to_jsonb(array[format('already has an open application for this job (id %s)', v_existing)]));
        v_refused := v_refused + 1;
        continue;
      end if;
    end if;
    v_id := gen_random_uuid();
    v_apps_created := v_apps_created + 1;
    if v_stale then v_stale_closed := v_stale_closed + 1; end if;
    v_events_planned := v_events_planned + (case when v_stage <> 'new' then 1 else 0 end) + (case when v_stale then 1 else 0 end);
    if v_final = 'hired' then
      -- Propose a person: email, then phone, then name with an employment
      -- record in the job's company; never created here.
      v_email := v_cinfo->>'email';
      if v_email is not null then
        select jsonb_build_object('person_id', p.id, 'full_name', p.full_name, 'match', 'email') into v_proposal
          from public.people p
          where p.archived_at is null and (p.personal_email = v_email::citext or p.work_email = v_email::citext)
          order by p.created_at limit 1;
      end if;
      if v_proposal is null and app.phone_key(v_cinfo->>'phone') is not null then
        select jsonb_build_object('person_id', p.id, 'full_name', p.full_name, 'match', 'phone') into v_proposal
          from public.people p
          where p.archived_at is null
            and app.phone_key(p.phone) = app.phone_key(v_cinfo->>'phone')
          order by p.created_at limit 1;
      end if;
      if v_proposal is null and app.name_key(v_cinfo->>'full_name') is not null then
        select jsonb_build_object('person_id', p.id, 'full_name', p.full_name, 'match', 'name') into v_proposal
          from public.people p
          where p.archived_at is null
            and app.name_key(p.full_name) = app.name_key(v_cinfo->>'full_name')
            and exists (select 1 from public.employment_periods ep
                        where ep.person_id = p.id and ep.company_id = (v_info->>'company_id')::uuid)
          order by p.created_at limit 1;
      end if;
      v_hires := v_hires || jsonb_build_object('application_id', v_id,
        'candidate', v_cinfo->>'full_name',
        'job', v_info->>'title', 'company', v_company_name->>(v_info->>'company_id'),
        'hired_date', v_row->>'hired_date', 'proposal', v_proposal);
    end if;
    insert into pg_temp.zoho_import_rows values ('application', v_row->>'zoho_id', jsonb_build_object(
      'id', v_id, 'create', true, 'job_id', v_info->>'id', 'company_id', v_info->>'company_id',
      'candidate_id', v_cinfo->>'id', 'source_key', v_cinfo->>'source_key', 'stage', v_stage, 'final', v_final,
      'stale', v_stale, 'close', v_close, 'close_assumed', v_close_assumed,
      'job_status', v_info->>'status', 'proposal', v_proposal));
  end loop;

  -- ---------------------------------------------------------------- notes
  for v_row in select * from jsonb_array_elements(coalesce(p_payload->'notes', '[]'::jsonb)) loop
    select info into v_info from pg_temp.zoho_import_rows
      where kind = 'application' and ref = coalesce(v_row->>'application_zoho_id', '');
    if v_info is null then
      v_verdicts := v_verdicts || jsonb_build_object('kind', 'note', 'ref', v_row->>'zoho_id',
        'problems', to_jsonb(array[format('application %s is not in the extract', coalesce(v_row->>'application_zoho_id', '(none)'))]));
      v_refused := v_refused + 1;
      continue;
    end if;
    if (v_info->>'create')::boolean then
      v_notes_planned := v_notes_planned + 1;
    end if;
  end loop;

  v_counts := jsonb_build_object(
    'jobs_created', v_jobs_created, 'jobs_skipped', v_jobs_skipped,
    'candidates_created', v_cands_created, 'candidates_skipped', v_cands_skipped,
    'applications_created', v_apps_created, 'applications_skipped', v_apps_skipped,
    'stale_closed', v_stale_closed, 'events_created', v_events_planned, 'notes_created', v_notes_planned,
    'users_resolved', jsonb_array_length(v_users_resolved), 'users_unresolved', jsonb_array_length(v_users_unresolved),
    'refused', v_refused, 'do_not_contact', v_dnc, 'contact_later', v_later,
    'possible_duplicates', jsonb_array_length(v_dups));

  if v_refused > 0 and p_commit then
    raise exception 'Import refused: % rows have problems. Fix the extract and run again.', v_refused;
  end if;
  if not p_commit then
    return jsonb_build_object('committed', false, 'counts', v_counts,
      'users', jsonb_build_object('resolved', v_users_resolved, 'unresolved', v_users_unresolved),
      'rows', v_verdicts, 'hires', v_hires, 'possible_duplicates', v_dups, 'assumptions', v_assumptions);
  end if;

  -- ================================================================ pass 2
  v_prev_rpc := current_setting('app.candidate_rpc', true);
  v_prev_import := current_setting('app.candidate_import', true);
  perform set_config('app.candidate_rpc', 'on', true);
  perform set_config('app.candidate_import', 'on', true);

  for v_row in select * from jsonb_array_elements(coalesce(p_payload->'jobs', '[]'::jsonb)) loop
    select info into v_info from pg_temp.zoho_import_rows where kind = 'job' and ref = v_row->>'zoho_id';
    if v_info is null or not (v_info->>'create')::boolean then continue; end if;
    begin
      insert into public.jobs (id, company_id, title, description, status, custom, created_at, updated_at)
      values ((v_info->>'id')::uuid, (v_info->>'company_id')::uuid, trim(v_row->>'title'), v_row->>'description',
              v_row->>'status',
              app.jsonb_object_or_empty(v_row->'custom') || jsonb_build_object('zoho',
                app.jsonb_object_or_empty(v_row->'custom'->'zoho')
                || jsonb_build_object('id', v_row->>'zoho_id', 'display_id', v_row->>'display_id')),
              coalesce(nullif(v_row->>'created_at', '')::timestamptz, now()),
              coalesce(nullif(v_row->>'modified_at', '')::timestamptz, nullif(v_row->>'created_at', '')::timestamptz, now()));
    exception when others then
      raise exception 'Row % (job): %', v_row->>'zoho_id', sqlerrm;
    end;
  end loop;

  for v_row in select * from jsonb_array_elements(p_payload->'candidates') loop
    select info into v_info from pg_temp.zoho_import_rows where kind = 'candidate' and ref = v_row->>'zoho_id';
    if v_info is null or not (v_info->>'create')::boolean then continue; end if;
    begin
      insert into public.candidates
        (id, full_name, email, phone, linkedin_url, current_title, current_employer, location, skills, summary,
         referred_by, provider, provider_ref, source_key, sourced_by,
         do_not_contact, do_not_contact_reason, do_not_contact_at, do_not_contact_by, contact_later, contact_again_after,
         custom, created_at, updated_at, last_activity_at)
      select (v_info->>'id')::uuid, trim(v_row->>'full_name'), nullif(trim(coalesce(v_row->>'email', '')), '')::citext,
             nullif(trim(coalesce(v_row->>'phone', '')), ''), nullif(trim(coalesce(v_row->>'linkedin_url', '')), ''),
             nullif(trim(coalesce(v_row->>'current_title', '')), ''), nullif(trim(coalesce(v_row->>'current_employer', '')), ''),
             nullif(trim(coalesce(v_row->>'location', '')), ''), app.candidate_skills(v_row->'skills'),
             nullif(trim(coalesce(v_row->>'summary', '')), ''), nullif(trim(coalesce(v_row->>'referred_by', '')), ''),
             'zoho_recruit', v_row->>'zoho_id', v_info->>'source_key',
             (v_user_person->>coalesce(v_row->>'owner_zoho_id', ''))::uuid,
             coalesce((v_row->>'do_not_contact')::boolean, false),
             case when coalesce((v_row->>'do_not_contact')::boolean, false) then trim(v_row->>'do_not_contact_reason') end,
             case when coalesce((v_row->>'do_not_contact')::boolean, false)
                  then coalesce(nullif(v_row->>'do_not_contact_at', '')::timestamptz, c.created_at) end,
             case when coalesce((v_row->>'do_not_contact')::boolean, false)
                  then (v_user_person->>coalesce(v_row->>'do_not_contact_by_zoho_id', ''))::uuid end,
             coalesce((v_row->>'contact_later')::boolean, false), null,
             app.jsonb_object_or_empty(v_row->'custom'),
             c.created_at,
             coalesce(nullif(v_row->>'updated_at', '')::timestamptz, c.created_at),
             coalesce(nullif(v_row->>'last_activity_at', '')::timestamptz, nullif(v_row->>'updated_at', '')::timestamptz, c.created_at)
      from (select coalesce(nullif(v_row->>'created_at', '')::timestamptz, now()) as created_at) c;
    exception when others then
      raise exception 'Row % (candidate): %', v_row->>'zoho_id', sqlerrm;
    end;
  end loop;

  for v_row in select * from jsonb_array_elements(coalesce(p_payload->'applications', '[]'::jsonb)) loop
    select info into v_info from pg_temp.zoho_import_rows where kind = 'application' and ref = v_row->>'zoho_id';
    if v_info is null or not (v_info->>'create')::boolean then continue; end if;
    v_stage := v_info->>'stage';
    v_final := v_info->>'final';
    v_stale := (v_info->>'stale')::boolean;
    v_close := nullif(v_info->>'close', '')::timestamptz;
    begin
      -- Inserted directly at the final stage: imported rows never pass
      -- through the touch trigger's update path.
      insert into public.applications
        (id, job_id, company_id, candidate_id, stage_key, source_key, source_provider, provider_ref, owner_id,
         received_at, created_at, updated_at, withdrawn_reason, rejected_reason, custom)
      select (v_info->>'id')::uuid, (v_info->>'job_id')::uuid, (v_info->>'company_id')::uuid, (v_info->>'candidate_id')::uuid,
             v_final, v_info->>'source_key', 'zoho_recruit', v_row->>'zoho_id',
             (v_user_person->>coalesce(v_row->>'modified_by_zoho_id', ''))::uuid,
             c.received_at, c.received_at, coalesce(nullif(v_row->>'modified_at', '')::timestamptz, c.received_at),
             case when v_final = 'withdrawn' then coalesce(nullif(v_row->>'withdrawn_reason', ''), case when v_stale then 'Job closed' end) end,
             case when v_final = 'rejected' then nullif(v_row->>'rejected_reason', '') end,
             app.jsonb_object_or_empty(v_row->'custom') || jsonb_build_object('zoho',
               app.jsonb_object_or_empty(v_row->'custom'->'zoho') || jsonb_strip_nulls(jsonb_build_object(
                 'associated_id', v_row->>'zoho_id', 'status', v_row->>'zoho_status', 'stage', v_row->>'zoho_stage',
                 'created_by', v_row->'custom'->'zoho'->>'created_by',
                 'modified_by', coalesce(v_user_name->>coalesce(v_row->>'modified_by_zoho_id', ''), v_row->>'modified_by_zoho_id'),
                 'modified_time', v_row->>'modified_at',
                 'hired_by', coalesce(v_user_name->>coalesce(v_row->>'hired_by_zoho_id', ''), v_row->>'hired_by_zoho_id'),
                 'hired_date', v_row->>'hired_date',
                 'close_date_assumed', case when v_stale then (v_info->>'close_assumed')::boolean end))
               || case when v_final = 'hired' then jsonb_build_object('proposed_person',
                    case when v_info->'proposal' is null or jsonb_typeof(v_info->'proposal') = 'null' then null
                         else jsonb_build_object('id', v_info->'proposal'->>'person_id',
                                                 'full_name', v_info->'proposal'->>'full_name',
                                                 'match', v_info->'proposal'->>'match') end)
                  else '{}'::jsonb end)
      from (select coalesce(nullif(v_row->>'received_at', '')::timestamptz, nullif(v_row->>'modified_at', '')::timestamptz, now()) as received_at) c;
      if v_stage <> 'new' then
        insert into public.application_events (application_id, kind, from_stage_key, to_stage_key, body, actor_id, created_at)
        values ((v_info->>'id')::uuid, 'stage_change', null, v_stage,
                format('Imported from Zoho Recruit: "%s".', coalesce(v_row->>'zoho_status', v_stage)),
                (v_user_person->>coalesce(v_row->>'modified_by_zoho_id', ''))::uuid,
                case when v_stage = 'hired' and nullif(v_row->>'hired_date', '') is not null
                     then ((v_row->>'hired_date')::date)::timestamp at time zone 'UTC'
                     else coalesce(nullif(v_row->>'modified_at', '')::timestamptz, nullif(v_row->>'received_at', '')::timestamptz, now()) end);
        v_events_created := v_events_created + 1;
      end if;
      if v_stale then
        insert into public.application_events (application_id, kind, from_stage_key, to_stage_key, body, actor_id, created_at)
        values ((v_info->>'id')::uuid, 'stage_change', v_stage, 'withdrawn',
                format('Imported from Zoho Recruit: the job was %s while this application was "%s".',
                       case when v_info->>'job_status' = 'filled' then 'filled' else 'cancelled' end,
                       coalesce(v_row->>'zoho_status', v_stage)),
                (v_user_person->>coalesce(v_row->>'modified_by_zoho_id', ''))::uuid,
                coalesce(v_close, now()));
        v_events_created := v_events_created + 1;
      end if;
    exception when others then
      raise exception 'Row % (application): %', v_row->>'zoho_id', sqlerrm;
    end;
  end loop;

  for v_row in select * from jsonb_array_elements(coalesce(p_payload->'notes', '[]'::jsonb)) loop
    select info into v_info from pg_temp.zoho_import_rows where kind = 'application' and ref = v_row->>'application_zoho_id';
    if v_info is null or not (v_info->>'create')::boolean then continue; end if;
    begin
      insert into public.application_events (application_id, kind, body, actor_id, created_at)
      values ((v_info->>'id')::uuid, 'note',
              case when coalesce(v_row->>'body', '') like '[Zoho %' then v_row->>'body'
                   else format('[Zoho %s · %s · %s] %s', coalesce(nullif(v_row->>'kind', ''), 'Notes'),
                               to_char(coalesce(nullif(v_row->>'created_at', '')::timestamptz, now()), 'DD Mon YYYY'),
                               coalesce(nullif(v_row->>'actor_name', ''), v_user_name->>coalesce(v_row->>'actor_zoho_id', ''), 'Zoho Recruit'),
                               coalesce(v_row->>'body', '')) end,
              (v_user_person->>coalesce(v_row->>'actor_zoho_id', ''))::uuid,
              coalesce(nullif(v_row->>'created_at', '')::timestamptz, now()));
      v_notes_created := v_notes_created + 1;
    exception when others then
      raise exception 'Row % (note): %', v_row->>'zoho_id', sqlerrm;
    end;
  end loop;

  -- --------------------------------------------------------- verification
  select count(*) into v_n from public.jobs
    where custom->'zoho'->>'id' in (select ref from pg_temp.zoho_import_rows where kind = 'job');
  if v_n <> v_jobs_created + v_jobs_skipped then
    raise exception 'Verification failed: % jobs planned, % found — nothing was written.', v_jobs_created + v_jobs_skipped, v_n;
  end if;
  select count(*) into v_n from public.candidates
    where provider = 'zoho_recruit' and provider_ref in (select ref from pg_temp.zoho_import_rows where kind = 'candidate');
  if v_n <> v_cands_created + v_cands_skipped then
    raise exception 'Verification failed: % candidates planned, % found — nothing was written.', v_cands_created + v_cands_skipped, v_n;
  end if;
  select count(*) into v_n from public.applications
    where source_provider = 'zoho_recruit' and provider_ref in (select ref from pg_temp.zoho_import_rows where kind = 'application');
  if v_n <> v_apps_created + v_apps_skipped then
    raise exception 'Verification failed: % applications planned, % found — nothing was written.', v_apps_created + v_apps_skipped, v_n;
  end if;
  if v_events_created <> v_events_planned or v_notes_created <> v_notes_planned then
    raise exception 'Verification failed: % events and % notes planned, % and % written — nothing was written.',
      v_events_planned, v_notes_planned, v_events_created, v_notes_created;
  end if;

  perform set_config('app.candidate_rpc', coalesce(nullif(v_prev_rpc, ''), 'off'), true);
  perform set_config('app.candidate_import', coalesce(nullif(v_prev_import, ''), 'off'), true);

  insert into public.activity_log (actor_person_id, actor_user_id, entity_type, entity_id, action, after)
    values (v_me, auth.uid(), 'zoho_recruit_import', null, 'INSERT', v_counts);
  return jsonb_build_object('committed', true, 'counts', v_counts,
    'users', jsonb_build_object('resolved', v_users_resolved, 'unresolved', v_users_unresolved),
    'rows', v_verdicts, 'hires', v_hires, 'possible_duplicates', v_dups, 'assumptions', v_assumptions);
end $$;

-- ------------------------------------------------------------------ grants
-- Policy expressions and generated columns run as the calling role.
grant execute on function
  app.can_source_candidates(), app.candidate_object_candidate(text),
  app.phone_key(text), app.name_key(text), app.linkedin_key(text), app.mask_email(text)
to authenticated;
-- postgres-only callers. assert_contactable is among them: its only callers
-- are the t0_guard_contact trigger function and open_application, both
-- security definer owned by postgres; callable by hand it would tell any
-- signed-in user who knows a uuid the candidate's name, archived state and
-- contact rule. The careers route (service role) never needs it either.
revoke all on function
  app.open_application(uuid, uuid, text, boolean),
  app.assert_contactable(uuid, boolean),
  app.jsonb_object_or_empty(jsonb),
  app.candidate_payload_problems(jsonb),
  app.candidate_skills(jsonb),
  app.candidate_matches(text, text, text, text, uuid),
  app.candidate_match_hint(uuid, text)
from public;
revoke all on function app.assert_contactable(uuid, boolean) from authenticated, service_role;
revoke all on function
  public.upsert_sourced_candidate(text, text, jsonb),
  public.add_candidate_to_job(uuid, uuid, text, boolean),
  public.set_contact_rule(uuid, jsonb),
  public.search_candidates(jsonb),
  public.link_hired_application(uuid, uuid),
  public.import_zoho_recruit(jsonb, boolean)
from public, anon;
grant execute on function
  public.upsert_sourced_candidate(text, text, jsonb),
  public.add_candidate_to_job(uuid, uuid, text, boolean),
  public.set_contact_rule(uuid, jsonb),
  public.search_candidates(jsonb),
  public.link_hired_application(uuid, uuid),
  public.import_zoho_recruit(jsonb, boolean)
to authenticated;
grant execute on function public.upsert_sourced_candidate(text, text, jsonb) to service_role;

-- ------------------------------------------------------------------ report
-- recruitment_report (0015) re-created with two lines changed: the sources
-- subquery reads applications.source_key first, then the channel; null stays
-- "Added by hand", never guessed.
create or replace function public.recruitment_report(
  p_company_id uuid,
  p_from date,
  p_to date
) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_from timestamptz := p_from::timestamptz;
  v_to timestamptz := (p_to + 1)::timestamptz;  -- inclusive end date
  v_kpis jsonb;
  v_funnel jsonb;
  v_sources jsonb;
  v_attention jsonb;
begin
  if app.current_person_id() is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  if not app.has_capability(p_company_id, 'jobs.view') then
    raise exception 'Viewing recruitment reports requires jobs.view in this company.'
      using errcode = '42501';
  end if;
  if p_to < p_from then
    raise exception 'The end date is before the start date.';
  end if;

  select jsonb_build_object(
    'open_roles', (select count(*) from public.jobs j
                   where j.company_id = p_company_id and j.status = 'open'),
    'active_candidates', (select count(*) from public.applications a
                          join public.jobs j on j.id = a.job_id
                          where a.company_id = p_company_id
                            and j.status in ('open', 'on_hold')
                            and a.stage_key not in ('hired', 'rejected', 'withdrawn')),
    'received', (select count(*) from public.applications a
                 where a.company_id = p_company_id
                   and a.received_at >= v_from and a.received_at < v_to),
    'hires', (select count(*) from app.report_hires(p_company_id) h
              where h.hired_at >= v_from and h.hired_at < v_to),
    'median_days_to_hire', (select round((percentile_cont(0.5) within group (
                              order by extract(epoch from (h.hired_at - a.received_at)) / 86400))::numeric, 1)
                            from app.report_hires(p_company_id) h join public.applications a on a.id = h.application_id
                            where h.hired_at >= v_from and h.hired_at < v_to),
    'avg_days_to_hire', (select round(avg(extract(epoch from (h.hired_at - a.received_at)) / 86400)::numeric, 1)
                         from app.report_hires(p_company_id) h join public.applications a on a.id = h.application_id
                         where h.hired_at >= v_from and h.hired_at < v_to)
  ) into v_kpis;

  -- Funnel per job: every job with an application received in range or
  -- currently open; stage counts are the applications' current stages.
  select coalesce(jsonb_agg(row_to_json(f)::jsonb order by f.received desc, f.title), '[]'::jsonb) into v_funnel
  from (
    select j.id as job_id, j.title, j.status,
           count(a.id) filter (where a.received_at >= v_from and a.received_at < v_to) as received,
           jsonb_build_object(
             'new',        count(a.id) filter (where a.stage_key = 'new'),
             'screening',  count(a.id) filter (where a.stage_key = 'screening'),
             'interview',  count(a.id) filter (where a.stage_key = 'interview'),
             'offer',      count(a.id) filter (where a.stage_key = 'offer'),
             'hired',      count(a.id) filter (where a.stage_key = 'hired'),
             'rejected',   count(a.id) filter (where a.stage_key = 'rejected'),
             'withdrawn',  count(a.id) filter (where a.stage_key = 'withdrawn')
           ) as stages,
           count(a.id) filter (where a.stage_key = 'hired') as hired
    from public.jobs j
    left join public.applications a on a.job_id = j.id
    where j.company_id = p_company_id
    group by j.id, j.title, j.status
    having j.status = 'open'
        or count(a.id) filter (where a.received_at >= v_from and a.received_at < v_to) > 0
  ) f;

  -- Sources: received in range, reached interview or beyond, hired.
  select coalesce(jsonb_agg(row_to_json(s)::jsonb order by s.received desc, s.source), '[]'::jsonb) into v_sources
  from (
    select coalesce(cs.label, c.label, 'Added by hand') as source,
           count(*) as received,
           count(*) filter (where a.stage_key in ('interview', 'offer', 'hired')
                            or exists (select 1 from public.application_events e
                                       where e.application_id = a.id and e.kind = 'stage_change'
                                         and e.to_stage_key in ('interview', 'offer', 'hired'))) as interviewed,
           count(*) filter (where a.stage_key = 'hired') as hired
    from public.applications a
    left join public.candidate_sources cs on cs.key = a.source_key
    left join public.channels c on c.key = a.source_channel_key
    where a.company_id = p_company_id
      and a.received_at >= v_from and a.received_at < v_to
    group by coalesce(cs.label, c.label, 'Added by hand')
  ) s;

  select jsonb_build_object(
    'overdue_next_actions', (select count(*) from public.applications a
                             where a.company_id = p_company_id
                               and a.stage_key not in ('hired', 'rejected', 'withdrawn')
                               and a.next_action_due is not null and a.next_action_due < current_date),
    'unassigned', (select count(*) from public.applications a
                   join public.jobs j on j.id = a.job_id
                   where a.company_id = p_company_id
                     and j.status = 'open'
                     and a.stage_key not in ('hired', 'rejected', 'withdrawn')
                     and a.owner_id is null),
    'stale', (select count(*) from public.applications a
              join public.jobs j on j.id = a.job_id
              where a.company_id = p_company_id
                and j.status = 'open'
                and a.stage_key not in ('hired', 'rejected', 'withdrawn')
                and coalesce((select max(e.created_at) from public.application_events e
                              where e.application_id = a.id and e.kind = 'stage_change'), a.received_at)
                    < now() - interval '14 days')
  ) into v_attention;

  return jsonb_build_object(
    'company_id', p_company_id,
    'from', p_from, 'to', p_to,
    'kpis', v_kpis, 'funnel', v_funnel, 'sources', v_sources, 'attention', v_attention
  );
end $$;
