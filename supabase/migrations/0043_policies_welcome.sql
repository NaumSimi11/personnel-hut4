-- 0043_policies_welcome.sql
-- Plan 050: policies as a library, and the welcome note.
--   1. policies.body — a policy may be written in the app; publish_policy
--      takes a body or a file. A default library is seeded holding-wide as
--      drafts with summaries and a starting body.
--   2. "Policies acknowledged" ticks itself once every published policy
--      that applies to the person is acknowledged at its current version.
--   3. First-day details per company (where, when, who to ask for, what to
--      bring) in companies.settings, the holding's underneath.
--   4. The welcome note built from the record, sent through the 0034
--      notification queue to the personal address (or the work one), filed
--      as a PDF through the 0042 generated_documents queue, ticking the
--      'welcome_note' line; re-sending allowed, the plan remembers when.

-- ------------------------------------------------------------- 1. text policies
alter table public.policies add column body text;

-- One signature only: the 0021 overload would make the RPC call ambiguous.
drop function if exists public.publish_policy(uuid, text, text, text);
create or replace function public.publish_policy(
  p_policy_id uuid,
  p_storage_path text default null,
  p_original_name text default null,
  p_mime_type text default null,
  p_body text default null
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_policy record;
  v_version int;
  v_body text := nullif(btrim(coalesce(p_body, '')), '');
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  select * into v_policy from public.policies where id = p_policy_id for update;
  if not found then
    raise exception 'Policy not found.';
  end if;
  if not app.can_publish_policy(v_policy.company_id) then
    raise exception 'Publishing needs policies.publish in this company (holding-wide: platform admin).' using errcode = '42501';
  end if;
  if v_policy.status = 'archived' then
    raise exception 'An archived policy cannot be published; create a new one.';
  end if;
  -- A new version needs something new: a file or a body.
  if v_policy.status = 'published' and p_storage_path is null and v_body is null then
    raise exception 'Attach the new file or write the new text to publish a new version.';
  end if;
  if coalesce(p_storage_path, v_policy.storage_path) is null and coalesce(v_body, v_policy.body) is null then
    raise exception 'Attach the policy document or write its text before publishing.';
  end if;
  v_version := case when v_policy.status = 'published' then v_policy.version + 1 else v_policy.version end;
  perform set_config('app.policy_transition', 'on', true);
  update public.policies
    set status = 'published', version = v_version, published_at = now(), published_by = v_me,
        storage_path = coalesce(p_storage_path, storage_path),
        original_name = coalesce(p_original_name, original_name),
        mime_type = coalesce(p_mime_type, mime_type),
        body = coalesce(v_body, body)
    where id = p_policy_id;
  perform set_config('app.policy_transition', 'off', true);
  -- A new version: every running checklist re-checks its 'policies' line.
  perform app.retick_policies_for(v_policy.company_id);
  return jsonb_build_object('status', 'published', 'version', v_version);
end $$;
revoke all on function public.publish_policy(uuid, text, text, text, text) from public, anon;
grant execute on function public.publish_policy(uuid, text, text, text, text) to authenticated, service_role;

-- The prepare trigger let a draft's file change freely; the body follows the same rule.
create or replace function app.prepare_policy() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    new.status := 'draft';
    new.version := 1;
    new.published_at := null;
    new.published_by := null;
  elsif current_setting('app.policy_transition', true) is distinct from 'on' then
    new.status := old.status;
    new.version := old.version;
    new.published_at := old.published_at;
    new.published_by := old.published_by;
    new.company_id := old.company_id;
    if old.status = 'published' and (new.storage_path is distinct from old.storage_path or new.body is distinct from old.body) then
      raise exception 'Publish a new version to change the file or text of a published policy.';
    end if;
  end if;
  if length(trim(coalesce(new.title, ''))) < 2 then
    raise exception 'Enter the policy title.';
  end if;
  new.title := trim(new.title);
  new.body := nullif(btrim(coalesce(new.body, '')), '');
  return new;
end $$;

-- The default library, holding-wide, as drafts HR edits and publishes.
insert into public.policies (company_id, title, summary, body)
select null, v.title, v.summary, v.body from (values
  ('Code of Conduct',
   'How we treat each other, clients and partners; conflicts of interest; confidentiality.',
   E'We act with honesty and respect towards colleagues, clients and partners.\n\nConflicts of interest are declared to your manager before they arise. Company and client information stays confidential during and after your employment.\n\nQuestions about this policy go to HR.'),
  ('Time off & leave',
   'Annual leave, sick leave, public holidays and how to request time off.',
   E'Annual leave is requested in Personnel and approved by your manager or HR. Sick leave is reported on the first day; a medical certificate is attached from the request when required.\n\nPublic holidays follow the statutory calendar of your country; company closures are announced in advance.'),
  ('Remote & hybrid work',
   'Where and when we work, availability, equipment and security when working away from the office.',
   E'Remote and hybrid arrangements are agreed with your manager. Core hours and availability are respected wherever you work.\n\nCompany equipment is used for company work and kept secure; the IT & data security policy applies in full outside the office.'),
  ('IT & data security',
   'Accounts, passwords, devices, data handling and what to do when something goes wrong.',
   E'Your accounts and passwords are personal and never shared. Devices are locked when unattended and kept up to date.\n\nPersonal and client data are handled only as your role requires. A lost device or a suspected breach is reported to IT immediately.'),
  ('Anti-harassment & equal opportunity',
   'A workplace free of harassment and discrimination; how to raise a concern.',
   E'We do not tolerate harassment or discrimination on any ground. Decisions about hiring, pay and progression are made on merit.\n\nA concern can be raised with your manager, HR or a director; it is looked into promptly and in confidence, without retaliation.'),
  ('Expenses & reimbursement',
   'What can be claimed, how, with which receipts and by when.',
   E'Reasonable business expenses agreed in advance are reimbursed against receipts, claimed within the month they arise.\n\nTravel is booked at economy rates unless agreed otherwise. Personal expenses are never claimed.')
) as v(title, summary, body)
where not exists (select 1 from public.policies p where p.company_id is null and p.title = v.title);

-- ------------------------------------------------------------- 2. self-tick
-- Every published policy that applies to the person (holding-wide + the
-- company's) acknowledged at its current version → the 'policies' line done.
create or replace function app.tick_policies(p_person_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare pl record;
begin
  for pl in select p.id, p.company_id from public.plans p
             where p.person_id = p_person_id and p.kind = 'onboarding' and p.status = 'in_progress' loop
    if not exists (
         select 1 from public.policies po
         where po.status = 'published' and (po.company_id is null or po.company_id = pl.company_id)
           and not exists (select 1 from public.policy_acknowledgements a
                           where a.policy_id = po.id and a.person_id = p_person_id and a.version = po.version))
       and exists (select 1 from public.policies po where po.status = 'published' and (po.company_id is null or po.company_id = pl.company_id)) then
      update public.plan_tasks set status = 'done', done_at = now(), done_by = coalesce(app.current_person_id(), p_person_id)
        where plan_id = pl.id and task_key = 'policies' and status in ('open', 'blocked');
    end if;
  end loop;
end $$;

create or replace function app.policy_ack_tick() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform app.tick_policies(new.person_id);
  return new;
end $$;
create trigger tick after insert on public.policy_acknowledgements for each row execute function app.policy_ack_tick();

-- A newly published policy: nothing un-ticks (the line is history), but a
-- running checklist whose person has already read everything else re-checks.
create or replace function app.retick_policies_for(p_company_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_person uuid;
begin
  for v_person in select distinct person_id from public.plans
                   where kind = 'onboarding' and status = 'in_progress' and (p_company_id is null or company_id = p_company_id) loop
    perform app.tick_policies(v_person);
  end loop;
end $$;

-- ---------------------------------------------------------- 3. first day
create or replace function app.first_day_for(p_company_id uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select coalesce(
    (select settings -> 'first_day' from public.companies where id = p_company_id
      and jsonb_typeof(settings -> 'first_day') = 'object' and app.jsonb_has_values(settings -> 'first_day')),
    (select settings -> 'first_day' from public.companies where kind = 'holding' and archived_at is null
      and jsonb_typeof(settings -> 'first_day') = 'object' order by created_at limit 1),
    '{}'::jsonb)
$$;
create or replace function public.first_day_details(p_company_id uuid) returns jsonb
language sql stable security definer set search_path = public as $$
  select jsonb_build_object(
    'details', app.first_day_for(p_company_id),
    'own', exists (select 1 from public.companies where id = p_company_id
                   and jsonb_typeof(settings -> 'first_day') = 'object' and app.jsonb_has_values(settings -> 'first_day')))
$$;
revoke all on function public.first_day_details(uuid) from public, anon;
grant execute on function public.first_day_details(uuid) to authenticated;
-- 0042 / 0041 granted these without the revoke: closed here.
revoke all on function public.starter_kit(uuid) from public, anon;
revoke all on function public.handover_fields() from public, anon;

/** {where, when, ask_for, bring} — tasks.assign here, or admin. Empty values fall back to the holding's. */
create or replace function public.set_first_day_details(p_company_id uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v jsonb;
begin
  if app.current_person_id() is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  if not (app.is_admin() or app.has_capability(p_company_id, 'tasks.assign')) then
    raise exception 'Setting the first-day details needs tasks.assign in this company.' using errcode = '42501';
  end if;
  v := jsonb_strip_nulls(jsonb_build_object(
    'where', nullif(left(btrim(coalesce(p ->> 'where', '')), 300), ''),
    'when', nullif(left(btrim(coalesce(p ->> 'when', '')), 120), ''),
    'ask_for', nullif(left(btrim(coalesce(p ->> 'ask_for', '')), 120), ''),
    'bring', nullif(left(btrim(coalesce(p ->> 'bring', '')), 300), '')));
  update public.companies set settings = settings || jsonb_build_object('first_day', v) where id = p_company_id;
  return jsonb_build_object('details', v);
end $$;
revoke all on function public.set_first_day_details(uuid, jsonb) from public, anon;
grant execute on function public.set_first_day_details(uuid, jsonb) to authenticated, service_role;

-- ------------------------------------------------------- 4. the welcome note
alter table public.plans add column welcome_sent_at timestamptz;
alter table public.plans add column welcome_sent_to text;

-- The note as plain text, from the record: the builder (no gate) and the
-- gated public reader over it.
create or replace function app.welcome_note_render(p_plan_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  pl public.plans;
  pe public.people;
  ep public.employment_periods;
  co public.companies;
  v_first jsonb;
  v_policies jsonb;
  v_manager text;
  v_dept text;
  v_hr text;
  v_lines text[] := '{}';
  v_pol record;
begin
  select * into pl from public.plans where id = p_plan_id;
  if not found then return null; end if;
  select * into pe from public.people where id = pl.person_id;
  select * into ep from public.employment_periods where id = pl.employment_period_id;
  select * into co from public.companies where id = pl.company_id;
  select full_name into v_manager from public.people where id = ep.manager_id;
  select name into v_dept from public.departments where id = ep.department_id;
  select full_name into v_hr from public.people where id = pl.hr_owner_id;
  v_first := app.first_day_for(pl.company_id);
  select coalesce(jsonb_agg(jsonb_build_object('title', po.title, 'summary', po.summary) order by po.title), '[]'::jsonb) into v_policies
    from public.policies po where po.status = 'published' and (po.company_id is null or po.company_id = pl.company_id);

  v_lines := array_append(v_lines, format('Dear %s,', coalesce(pe.preferred_name, split_part(pe.full_name, ' ', 1))));
  v_lines := array_append(v_lines, '');
  v_lines := array_append(v_lines, format('Welcome to %s. We are glad you are joining us as %s%s, starting on %s%s.',
    co.name, ep.job_title, coalesce(' in ' || v_dept, ''), to_char(ep.start_date, 'DD FMMonth YYYY'),
    coalesce('. Your manager will be ' || v_manager, '')));
  if app.jsonb_has_values(v_first) then
    v_lines := array_append(v_lines, '');
    v_lines := array_append(v_lines, 'Your first day');
    if v_first ->> 'where' is not null then v_lines := array_append(v_lines, format('Where: %s', v_first ->> 'where')); end if;
    if v_first ->> 'when' is not null then v_lines := array_append(v_lines, format('When: %s', v_first ->> 'when')); end if;
    if v_first ->> 'ask_for' is not null then v_lines := array_append(v_lines, format('Ask for: %s', v_first ->> 'ask_for')); end if;
    if v_first ->> 'bring' is not null then v_lines := array_append(v_lines, format('Please bring: %s', v_first ->> 'bring')); end if;
  end if;
  if jsonb_array_length(v_policies) > 0 then
    v_lines := array_append(v_lines, '');
    v_lines := array_append(v_lines, 'Our policies');
    for v_pol in select * from jsonb_to_recordset(v_policies) as x(title text, summary text) loop
      v_lines := array_append(v_lines, format('• %s%s', v_pol.title, coalesce(' — ' || v_pol.summary, '')));
    end loop;
    v_lines := array_append(v_lines, 'Please read and acknowledge them in Personnel under My workspace once you have your account.');
  end if;
  v_lines := array_append(v_lines, '');
  v_lines := array_append(v_lines, 'See you soon,');
  v_lines := array_append(v_lines, coalesce(v_hr, 'HR') || ', ' || co.name);

  return jsonb_build_object(
    'subject', format('Welcome to %s, %s', co.name, coalesce(pe.preferred_name, split_part(pe.full_name, ' ', 1))),
    'text', array_to_string(v_lines, E'\n'),
    'lines', to_jsonb(v_lines),
    'personal_email', pe.personal_email,
    'work_email', pe.work_email,
    'sent_at', pl.welcome_sent_at,
    'sent_to', pl.welcome_sent_to,
    'policies', v_policies,
    'first_day', v_first);
end $$;

/** Readable by the person and by anyone with tasks.view in the company. */
create or replace function public.welcome_note_text(p_plan_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare pl public.plans;
begin
  select * into pl from public.plans where id = p_plan_id;
  if not found or not (app.is_self(pl.person_id) or app.has_capability(pl.company_id, 'tasks.view')) then
    raise exception 'Checklist not found.' using errcode = 'P0002';
  end if;
  return app.welcome_note_render(p_plan_id);
end $$;
revoke all on function public.welcome_note_text(uuid) from public, anon;
grant execute on function public.welcome_note_text(uuid) to authenticated, service_role;

/**
 * Send the welcome note: a notification row for the person carrying the
 * note (the 0034 queue delivers it and records the outcome), the PDF
 * queued (0042), the 'welcome_note' line ticked. p_to = 'personal' (the
 * address they applied from, the default — the work mailbox may not exist
 * yet) or 'work'. Re-sending is allowed; the plan remembers the last time.
 */
create or replace function public.send_welcome_note(p_plan_id uuid, p_to text default 'personal') returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  pl public.plans;
  n jsonb;
  v_email text;
  v_key text;
begin
  if app.current_person_id() is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  select * into pl from public.plans where id = p_plan_id;
  if not found then
    raise exception 'Checklist not found.' using errcode = 'P0002';
  end if;
  if not app.has_capability(pl.company_id, 'tasks.assign') then
    raise exception 'Sending the welcome note needs tasks.assign in this company.' using errcode = '42501';
  end if;
  if pl.kind <> 'onboarding' then
    raise exception 'The welcome note belongs to an onboarding checklist.' using errcode = '22023';
  end if;
  if p_to not in ('personal', 'work') then
    raise exception 'Send it to the personal or the work address.' using errcode = '22023';
  end if;
  n := public.welcome_note_text(p_plan_id);
  v_email := case when p_to = 'personal' then n ->> 'personal_email' else n ->> 'work_email' end;
  -- Each send is its own row: clock_timestamp() (now() is fixed per transaction) plus a nonce.
  v_key := 'welcome:' || p_plan_id || ':' || clock_timestamp() || ':' || gen_random_uuid();
  insert into public.notifications (person_id, company_id, kind, title, body, link, entity_type, entity_id, dedupe_key, email_to, email_status)
    values (pl.person_id, pl.company_id, 'welcome.note', n ->> 'subject', n ->> 'text', '/me', 'plan', p_plan_id, v_key,
            v_email, case when v_email is null then 'skipped' else 'pending' end);
  perform app.queue_generated_document('welcome_note', pl.person_id, p_plan_id, 'plan:' || p_plan_id || ':' || clock_timestamp());
  update public.plans set welcome_sent_at = now(), welcome_sent_to = p_to where id = p_plan_id;
  update public.plan_tasks set status = 'done', done_at = now(), done_by = app.current_person_id()
    where plan_id = p_plan_id and task_key = 'welcome_note' and status in ('open', 'blocked');
  return jsonb_build_object('to', v_email, 'status', case when v_email is null then 'skipped' else 'pending' end,
    'note', case when v_email is null then 'No ' || p_to || ' email on the record — the note is in the app and filed as a PDF; copy it to send by hand.' end);
end $$;
revoke all on function public.send_welcome_note(uuid, text) from public, anon;
grant execute on function public.send_welcome_note(uuid, text) to authenticated, service_role;

/** What the welcome note PDF prints (service role, from the queue row). */
create or replace function public.welcome_note_data(p_queue_id uuid) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare q public.generated_documents; n jsonb; co text;
begin
  select * into q from public.generated_documents where id = p_queue_id;
  if not found or q.plan_id is null then return null; end if;
  n := app.welcome_note_render(q.plan_id);
  select name into co from public.companies where id = q.company_id;
  return n || jsonb_build_object('company', co);
end $$;
revoke all on function public.welcome_note_data(uuid) from public, anon, authenticated;
grant execute on function public.welcome_note_data(uuid) to service_role;

-- ------------------------------------------------- 5. review of 0041's gate
-- Changing where a trusted recipient's sensitive fields go (kind / address /
-- person / role) is as sensitive as putting the fields there: whoever does it
-- must hold the capability for every sensitive field the recipient keeps.
create or replace function public.save_handover_recipient(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid := nullif(p ->> 'id', '')::uuid;
  v_company uuid := nullif(p ->> 'company_id', '')::uuid;
  v_kind text := p ->> 'kind';
  v_events text[] := coalesce((select array_agg(x) from jsonb_array_elements_text(coalesce(p -> 'events', '[]'::jsonb)) x), '{}');
  v_fields text[] := coalesce((select array_agg(x) from jsonb_array_elements_text(coalesce(p -> 'fields', '[]'::jsonb)) x), '{}');
  v_trusted boolean := coalesce((p ->> 'trusted')::boolean, false);
  v_old public.handover_recipients;
  v_check text[];
  v_f text;
  v_sens text;
  v_target_changed boolean := false;
begin
  if app.current_person_id() is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  if v_company is null then
    if not app.is_admin() then
      raise exception 'The holding default is the admins'' to change.' using errcode = '42501';
    end if;
  elsif not app.has_capability(v_company, 'tasks.assign') then
    raise exception 'Shaping the handover needs tasks.assign in this company.' using errcode = '42501';
  end if;
  if v_kind not in ('role', 'person', 'email') then
    raise exception 'Choose who the recipient is: a role, a colleague or an address.' using errcode = '22023';
  end if;
  if v_kind = 'role' and (p ->> 'role_key') <> 'manager'
     and not exists (select 1 from public.workflow_roles where key = p ->> 'role_key') then
    raise exception 'Unknown role.' using errcode = '22023';
  end if;
  if v_kind = 'person' and not exists (select 1 from public.people where id = nullif(p ->> 'person_id', '')::uuid and archived_at is null) then
    raise exception 'Choose the colleague.' using errcode = '22023';
  end if;
  if not (v_fields <@ (select array_agg(key) from app.handover_fields())) then
    raise exception 'Unknown field on the list.' using errcode = '22023';
  end if;
  if v_id is not null then
    select * into v_old from public.handover_recipients where id = v_id and company_id is not distinct from v_company;
    if not found then
      raise exception 'Recipient not found.' using errcode = 'P0002';
    end if;
    v_target_changed := v_old.kind is distinct from v_kind
      or v_old.role_key is distinct from (case when v_kind = 'role' then p ->> 'role_key' end)
      or v_old.person_id is distinct from (case when v_kind = 'person' then nullif(p ->> 'person_id', '')::uuid end)
      or v_old.email is distinct from (case when v_kind = 'email' then lower(nullif(btrim(coalesce(p ->> 'email', '')), '')) end);
  end if;
  -- Fields to check: the ones being added, plus every sensitive one kept when the target moves.
  v_check := (select coalesce(array_agg(x), '{}') from unnest(v_fields) x where v_old.id is null or not (x = any(v_old.fields)));
  if v_target_changed then
    v_check := v_check || (select coalesce(array_agg(x), '{}') from unnest(v_fields) x where x = any(v_old.fields));
  end if;
  foreach v_f in array v_check loop
    select sensitivity into v_sens from app.handover_fields() where key = v_f;
    if v_sens <> 'plain' then
      if not v_trusted then
        raise exception 'Only a trusted recipient may receive %.', (select label from app.handover_fields() where key = v_f)
          using errcode = '22023';
      end if;
      if v_company is null and not app.is_admin() then
        raise exception 'Sensitive fields on the holding default are the admins'' to set.' using errcode = '42501';
      end if;
      if v_company is not null and not app.has_capability(v_company, case when v_sens = 'pay' then 'salary.view' else 'personal.view' end) then
        raise exception 'Putting % on a recipient, or changing who receives it, needs % in this company.',
          (select label from app.handover_fields() where key = v_f),
          case when v_sens = 'pay' then 'salary.view' else 'personal.view' end
          using errcode = '42501';
      end if;
    end if;
  end loop;

  if v_id is null then
    insert into public.handover_recipients (company_id, label, kind, role_key, person_id, email, events, fields, trusted, active, sort_order)
      values (v_company, btrim(p ->> 'label'), v_kind,
              case when v_kind = 'role' then p ->> 'role_key' end,
              case when v_kind = 'person' then nullif(p ->> 'person_id', '')::uuid end,
              case when v_kind = 'email' then lower(nullif(btrim(coalesce(p ->> 'email', '')), '')) end,
              v_events, v_fields, v_trusted, coalesce((p ->> 'active')::boolean, true),
              coalesce((select max(sort_order) from public.handover_recipients where company_id is not distinct from v_company), 0) + 10)
      returning id into v_id;
  else
    update public.handover_recipients
       set label = btrim(p ->> 'label'), kind = v_kind,
           role_key = case when v_kind = 'role' then p ->> 'role_key' end,
           person_id = case when v_kind = 'person' then nullif(p ->> 'person_id', '')::uuid end,
           email = case when v_kind = 'email' then lower(nullif(btrim(coalesce(p ->> 'email', '')), '')) end,
           events = v_events, fields = v_fields, trusted = v_trusted,
           active = coalesce((p ->> 'active')::boolean, active)
     where id = v_id;
  end if;
  return jsonb_build_object('id', v_id);
end $$;
