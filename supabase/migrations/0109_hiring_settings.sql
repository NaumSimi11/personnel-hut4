-- 0109_hiring_settings.sql
-- Hiring settings HR can change (Hiring Module user flows, 11 Nov 2026:
-- screen 9.13 "Settings: ... email templates, reason codes", 3.3 pipeline
-- templates, 10.8 time limits).
--
--   * hiring_settings: the time limits, holding-wide (company_id null) or per
--     company. app.hiring_setting() reads company, then holding, then the
--     built-in default; every clock and default now goes through it.
--   * email_templates: the wording of each candidate email, holding-wide or
--     per company, with {candidate} {job} {company} {salary} {start_date}
--     {expires_on}. No row -> the built-in wording in the server.
--   * rejection_reasons: the reason codes a rejection must carry (5.x),
--     stored on the application as reason_code.
--   * pipeline_templates: named sets of optional stages to switch off,
--     applied to a job before it opens.
-- Admins and people who manage a company's access edit them.

begin;

-- ------------------------------------------------------------- time limits
create table public.hiring_settings (
  id uuid primary key default gen_random_uuid(),
  company_id uuid references public.companies(id) on delete cascade,
  key text not null check (key in ('first_response_days', 'offer_expiry_days', 'offer_warn_days',
    'feedback_remind_hours', 'feedback_escalate_hours', 'source_credit_days', 'approval_overdue_days',
    'approval_escalate_days')),
  value int not null check (value between 0 and 3650),
  updated_at timestamptz not null default now(),
  unique nulls not distinct (company_id, key)
);
alter table public.hiring_settings enable row level security;
create policy sel on public.hiring_settings for select to authenticated using (true);
create policy write on public.hiring_settings for all to authenticated
  using (app.is_admin() or (company_id is not null and app.has_capability(company_id, 'access.manage')))
  with check (app.is_admin() or (company_id is not null and app.has_capability(company_id, 'access.manage')));
grant select, insert, update, delete on public.hiring_settings to authenticated;
grant all on public.hiring_settings to service_role;
create trigger audit after insert or update or delete on public.hiring_settings
  for each row execute function app.audit();

create or replace function app.hiring_setting(p_company uuid, p_key text) returns int
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select value from public.hiring_settings where company_id = p_company and key = p_key),
    (select value from public.hiring_settings where company_id is null and key = p_key),
    case p_key
      when 'first_response_days' then 3
      when 'offer_expiry_days' then 7
      when 'offer_warn_days' then 2
      when 'feedback_remind_hours' then 24
      when 'feedback_escalate_hours' then 48
      when 'source_credit_days' then 90
      when 'approval_overdue_days' then 3
      when 'approval_escalate_days' then 7
    end)
$$;
grant execute on function app.hiring_setting(uuid, text) to authenticated;

-- ------------------------------------------------------------ email wording
create table public.email_templates (
  id uuid primary key default gen_random_uuid(),
  company_id uuid references public.companies(id) on delete cascade,
  kind text not null check (kind in ('received', 'rejected', 'withdrawn', 'offer', 'offer_reminder')),
  subject text not null check (length(trim(subject)) between 1 and 200),
  body text not null check (length(trim(body)) between 1 and 8000),
  updated_at timestamptz not null default now(),
  unique nulls not distinct (company_id, kind)
);
alter table public.email_templates enable row level security;
create policy sel on public.email_templates for select to authenticated
  using (company_id is null or app.has_capability(company_id, 'candidates.view') or app.has_capability(company_id, 'access.manage'));
create policy write on public.email_templates for all to authenticated
  using (app.is_admin() or (company_id is not null and app.has_capability(company_id, 'access.manage')))
  with check (app.is_admin() or (company_id is not null and app.has_capability(company_id, 'access.manage')));
grant select, insert, update, delete on public.email_templates to authenticated;
grant all on public.email_templates to service_role;
create trigger audit after insert or update or delete on public.email_templates
  for each row execute function app.audit();

-- ---------------------------------------------------------- reason codes
create table public.rejection_reasons (
  key text primary key check (key ~ '^[a-z][a-z0-9_]{1,39}$'),
  label text not null check (length(trim(label)) between 1 and 80),
  sort_order int not null default 0,
  archived_at timestamptz
);
alter table public.rejection_reasons enable row level security;
create policy read_all on public.rejection_reasons for select to authenticated using (true);
create policy admin_write on public.rejection_reasons for all to authenticated
  using (app.is_admin()) with check (app.is_admin());
grant select, insert, update, delete on public.rejection_reasons to authenticated;
grant all on public.rejection_reasons to service_role;
insert into public.rejection_reasons (key, label, sort_order) values
  ('skills', 'Skills or experience do not match', 10),
  ('salary', 'Salary expectations too far apart', 20),
  ('availability', 'Availability or notice period', 30),
  ('culture', 'Team or culture fit', 40),
  ('position_filled', 'Position filled by another candidate', 50),
  ('other', 'Other', 90);

alter table public.applications add column reason_code text references public.rejection_reasons(key);

/** The app's door: the reason code of rejected applications (after set_application_status). */
create or replace function public.set_reason_code(p_application_ids uuid[], p_reason_code text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_id uuid; v_app record; v_n int := 0;
begin
  if app.current_person_id() is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  if not exists (select 1 from public.rejection_reasons where key = p_reason_code and archived_at is null) then
    raise exception 'Pick a reason code.' using errcode = '22023';
  end if;
  for v_id in select distinct u.id from unnest(coalesce(p_application_ids, '{}')) u(id) loop
    select a.id, a.company_id, s.outcome into v_app
      from public.applications a left join public.application_sub_statuses s on s.key = a.sub_status_key
     where a.id = v_id;
    if not found then continue; end if;
    if not app.has_capability(v_app.company_id, 'candidates.review') then
      raise exception 'You need "Record interview feedback" here.' using errcode = '42501';
    end if;
    if v_app.outcome is distinct from 'rejected' then continue; end if;
    update public.applications set reason_code = p_reason_code where id = v_id;
    v_n := v_n + 1;
  end loop;
  return jsonb_build_object('set', v_n);
end $$;
grant execute on function public.set_reason_code(uuid[], text) to authenticated;

-- ------------------------------------------------------ pipeline templates
create table public.pipeline_templates (
  id uuid primary key default gen_random_uuid(),
  company_id uuid references public.companies(id) on delete cascade,
  name text not null check (length(trim(name)) between 1 and 80),
  skip_statuses text[] not null default '{}'
    check (skip_statuses <@ array['interview_task', 'interview_hr', 'interview_stakeholders']::text[]),
  unique nulls not distinct (company_id, name)
);
alter table public.pipeline_templates enable row level security;
create policy sel on public.pipeline_templates for select to authenticated using (true);
create policy write on public.pipeline_templates for all to authenticated
  using (app.is_admin() or (company_id is not null and app.has_capability(company_id, 'access.manage')))
  with check (app.is_admin() or (company_id is not null and app.has_capability(company_id, 'access.manage')));
grant select, insert, update, delete on public.pipeline_templates to authenticated;
grant all on public.pipeline_templates to service_role;
insert into public.pipeline_templates (company_id, name, skip_statuses) values
  (null, 'Full pipeline', '{}'),
  (null, 'Short: no test, no final interview', array['interview_task', 'interview_stakeholders']),
  (null, 'Technical role: no HR interview', array['interview_hr']);

-- ------------------------------------- the defaults now read the settings
create or replace function app.offer_expiry_default() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.status = 'extended' and old.status is distinct from 'extended' and new.expires_on is null then
    new.expires_on := current_date + app.hiring_setting(new.company_id, 'offer_expiry_days');
  end if;
  return new;
end $$;

create or replace function app.credit_earliest_source() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  select a.source_key into new.credited_source_key
    from public.applications a
   where a.candidate_id = new.candidate_id and a.id <> new.id
     and a.received_at > coalesce(new.received_at, now())
                         - make_interval(days => app.hiring_setting(new.company_id, 'source_credit_days'))
     and a.source_key is not null
   order by a.received_at
   limit 1;
  new.credited_source_key := coalesce(new.credited_source_key, new.source_key);
  return new;
end $$;

commit;
