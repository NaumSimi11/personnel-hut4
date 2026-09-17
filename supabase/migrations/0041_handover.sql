-- 0041_handover.sql
-- Plan 048: the handover — who · where · what, green or red.
-- When someone is hired, finishes onboarding, is scheduled to leave or is
-- marked former, the people who must know (IT, the accountant, the manager)
-- get an email with exactly the fields configured for them, and HR sees per
-- recipient whether it went. Personal data leaves the database only this
-- way: a field reaches a recipient only when it is on the recipient's list,
-- the recipient is trusted for sensitive fields, and whoever put it there
-- held the capability to see it.

-- Where IT-side mail goes for a company (empty = the IT owner's own address).
alter table public.companies add column it_notification_email text
  check (it_notification_email is null or it_notification_email ~ '^[^\s@]+@[^\s@]+\.[^\s@]+$');

-- ------------------------------------------------------------ 1. catalogue
-- Every field a handover can carry, with its label and whether it is
-- sensitive (personal.view to configure, trusted recipient to receive) or
-- pay (salary.view to configure, trusted to receive).
create or replace function app.handover_fields() returns table (key text, label text, sensitivity text)
language sql immutable as $$
  select * from (values
    ('name',            'Full name',                 'plain'),
    ('work_email',      'Work email',                'plain'),
    ('position',        'Position',                  'plain'),
    ('department',      'Department',                'plain'),
    ('location',        'Location',                  'plain'),
    ('company',         'Company',                   'plain'),
    ('employment_type', 'Employment type',           'plain'),
    ('start_date',      'Start date',                'plain'),
    ('end_date',        'Employment end date',       'plain'),
    ('last_working_date','Last working day',         'plain'),
    ('manager',         'Manager',                   'plain'),
    ('starter_kit',     'Starter kit',               'plain'),
    ('equipment_held',  'Equipment held',            'plain'),
    ('personal_email',  'Personal email',            'personal'),
    ('phone',           'Personal phone',            'personal'),
    ('birth_date',      'Date of birth',             'personal'),
    ('address',         'Home address',              'personal'),
    ('national_id',     'National ID number',        'personal'),
    ('bank_account',    'Bank account',              'personal'),
    ('salary',          'Salary',                    'pay')
  ) as f(key, label, sensitivity)
$$;
grant execute on function app.handover_fields() to authenticated;

create or replace function public.handover_fields() returns jsonb
language sql stable as $$
  select coalesce(jsonb_agg(jsonb_build_object('key', key, 'label', label, 'sensitivity', sensitivity)), '[]'::jsonb)
  from app.handover_fields()
$$;
grant execute on function public.handover_fields() to authenticated;

-- ------------------------------------------------------------ 2. recipients
create table public.handover_recipients (
  id uuid primary key default gen_random_uuid(),
  company_id uuid references public.companies(id),      -- null = holding default
  label text not null check (length(label) between 2 and 80),
  kind text not null check (kind in ('role', 'person', 'email')),
  role_key text,                 -- a workflow_roles key, or 'manager' (the period's manager)
  person_id uuid references public.people(id),
  email text check (email is null or email ~ '^[^\s@]+@[^\s@]+\.[^\s@]+$'),
  events text[] not null default '{}',
  fields text[] not null default '{}',
  trusted boolean not null default false,
  active boolean not null default true,
  sort_order int not null default 0,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint handover_recipient_target check (
    (kind = 'role' and role_key is not null) or
    (kind = 'person' and person_id is not null) or
    (kind = 'email')),
  constraint handover_events_known check (
    events <@ array['hire_confirmed', 'onboarding_finished', 'departure_scheduled', 'marked_former'])
);
create index handover_recipients_company_idx on public.handover_recipients (company_id) where active;
create trigger touch before update on public.handover_recipients for each row execute function app.touch_updated_at();
alter table public.handover_recipients enable row level security;
create policy sel on public.handover_recipients for select to authenticated
  using (company_id is null or app.has_capability(company_id, 'tasks.view'));
grant select on public.handover_recipients to authenticated;
grant all on public.handover_recipients to service_role;
create trigger audit after insert or update or delete on public.handover_recipients
  for each row execute function app.audit_redacted('email');

-- Seeded defaults for the holding. The accountant's address is empty on
-- purpose: every send to them is "missing: address" until it is filled.
insert into public.handover_recipients (company_id, label, kind, role_key, events, fields, trusted, sort_order) values
  (null, 'IT', 'role', 'it_owner', array['hire_confirmed', 'departure_scheduled', 'marked_former'],
   array['name', 'work_email', 'position', 'department', 'start_date', 'end_date', 'last_working_date', 'starter_kit', 'equipment_held'], false, 10);
insert into public.handover_recipients (company_id, label, kind, email, events, fields, trusted, sort_order) values
  (null, 'Accountant', 'email', null, array['hire_confirmed', 'marked_former'],
   array['name', 'national_id', 'bank_account', 'salary', 'start_date', 'end_date'], true, 20);
-- 'manager' is not a workflow owner (it would show under Settings → Workflow
-- owners as assignable): it resolves to the period's manager.
insert into public.handover_recipients (company_id, label, kind, role_key, events, fields, trusted, sort_order) values
  (null, 'Manager', 'role', 'manager', array['hire_confirmed'],
   array['name', 'position', 'department', 'start_date'], false, 30);

/**
 * Add or change a recipient. p: {id?, company_id* (null only for admins),
 * label*, kind*, role_key, person_id, email, events[], fields[], trusted,
 * active}. A sensitive field may be put on a recipient only by someone who
 * may see it here (personal.view / salary.view) and only on a trusted
 * recipient; the check is on the change, so a field already there stays.
 */
create or replace function public.save_handover_recipient(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_id uuid := nullif(p ->> 'id', '')::uuid;
  v_company uuid := nullif(p ->> 'company_id', '')::uuid;
  v_kind text := p ->> 'kind';
  v_events text[] := coalesce((select array_agg(x) from jsonb_array_elements_text(coalesce(p -> 'events', '[]'::jsonb)) x), '{}');
  v_fields text[] := coalesce((select array_agg(x) from jsonb_array_elements_text(coalesce(p -> 'fields', '[]'::jsonb)) x), '{}');
  v_trusted boolean := coalesce((p ->> 'trusted')::boolean, false);
  v_old text[] := '{}';
  v_new text[];
  v_f text;
  v_sens text;
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
    select fields into v_old from public.handover_recipients where id = v_id and company_id is not distinct from v_company;
    if not found then
      raise exception 'Recipient not found.' using errcode = 'P0002';
    end if;
  end if;
  -- Fields being added: sensitive ones need the capability here and a trusted recipient.
  v_new := (select coalesce(array_agg(x), '{}') from unnest(v_fields) x where not (x = any(v_old)));
  foreach v_f in array v_new loop
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
        raise exception 'Putting % on a recipient needs % in this company.',
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
revoke all on function public.save_handover_recipient(jsonb) from public, anon;
grant execute on function public.save_handover_recipient(jsonb) to authenticated, service_role;

create or replace function public.remove_handover_recipient(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_company uuid; v_found boolean;
begin
  select company_id, true into v_company, v_found from public.handover_recipients where id = p_id;
  if v_found is null then
    raise exception 'Recipient not found.' using errcode = 'P0002';
  end if;
  if (v_company is null and not app.is_admin()) or (v_company is not null and not app.has_capability(v_company, 'tasks.assign')) then
    raise exception 'Shaping the handover needs tasks.assign in this company.' using errcode = '42501';
  end if;
  update public.handover_recipients set active = false where id = p_id;
  return jsonb_build_object('id', p_id);
end $$;
revoke all on function public.remove_handover_recipient(uuid) from public, anon;
grant execute on function public.remove_handover_recipient(uuid) to authenticated, service_role;

-- The company's active recipients, else the holding's (same rule as templates).
create or replace function app.handover_recipients_for(p_company_id uuid) returns setof public.handover_recipients
language sql stable security definer set search_path = public as $$
  select * from public.handover_recipients r
  where r.active and r.company_id = p_company_id
  union all
  select * from public.handover_recipients r
  where r.active and r.company_id is null
    and not exists (select 1 from public.handover_recipients c where c.active and c.company_id = p_company_id)
  order by sort_order
$$;

-- ------------------------------------------------------------ 3. sends
create table public.handover_sends (
  id uuid primary key default gen_random_uuid(),
  person_id uuid not null references public.people(id) on delete cascade,
  company_id uuid not null references public.companies(id),
  plan_id uuid references public.plans(id) on delete set null,
  employment_period_id uuid references public.employment_periods(id) on delete set null,
  recipient_id uuid references public.handover_recipients(id) on delete set null,
  recipient_label text not null,
  event text not null check (event in ('hire_confirmed', 'onboarding_finished', 'departure_scheduled', 'marked_former')),
  to_email text,
  fields jsonb not null default '{}'::jsonb,        -- {key: {label, value}}
  stripped text[] not null default '{}',            -- configured but withheld (not trusted)
  missing text[] not null default '{}',             -- configured but empty on the record
  status text not null default 'pending' check (status in ('pending', 'sent', 'failed', 'missing', 'manual', 'cancelled')),
  error text,
  attempts int not null default 0,
  sent_at timestamptz,
  marked_by uuid references public.people(id),
  dedupe_key text not null unique,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index handover_sends_person_idx on public.handover_sends (person_id, created_at desc);
create index handover_sends_plan_idx on public.handover_sends (plan_id) where plan_id is not null;
create index handover_sends_pending_idx on public.handover_sends (created_at) where status = 'pending';
create trigger touch before update on public.handover_sends for each row execute function app.touch_updated_at();
alter table public.handover_sends enable row level security;
create policy sel on public.handover_sends for select to authenticated
  using (app.has_capability(company_id, 'tasks.view'));
grant select on public.handover_sends to authenticated;
grant all on public.handover_sends to service_role;
-- The snapshot carries the values that went out; the audit keeps only the fact.
create trigger audit after insert or update or delete on public.handover_sends
  for each row execute function app.audit_redacted('fields,to_email');

-- Where a recipient's mail goes for this person and company.
create or replace function app.handover_address(r public.handover_recipients, p_period_id uuid, p_company_id uuid) returns text
language sql stable security definer set search_path = public as $$
  select case r.kind
    when 'email' then r.email
    when 'person' then (select p.work_email::text from public.people p where p.id = r.person_id and p.archived_at is null)
    when 'role' then case
      when r.role_key = 'manager' then (select m.work_email::text from public.employment_periods ep join public.people m on m.id = ep.manager_id where ep.id = p_period_id)
      when r.role_key = 'it_owner' then coalesce(
        (select it_notification_email from public.companies where id = p_company_id),
        (select p.work_email::text from public.workflow_owners w join public.people p on p.id = w.person_id where w.company_id = p_company_id and w.role_key = 'it_owner'))
      else (select p.work_email::text from public.workflow_owners w join public.people p on p.id = w.person_id where w.company_id = p_company_id and w.role_key = r.role_key)
    end
  end
$$;

/** The value of one catalogue field for one person and period, as text; null when empty. */
create or replace function app.handover_value(p_key text, p_person_id uuid, p_period_id uuid) returns text
language plpgsql stable security definer set search_path = public as $$
declare
  ep public.employment_periods;
  pe public.people;
  pd public.person_private_details;
begin
  select * into ep from public.employment_periods where id = p_period_id;
  select * into pe from public.people where id = p_person_id;
  select * into pd from public.person_private_details where person_id = p_person_id;
  return case p_key
    when 'name' then pe.full_name
    when 'work_email' then pe.work_email::text
    when 'personal_email' then pe.personal_email::text
    when 'phone' then pe.phone
    when 'position' then ep.job_title
    when 'department' then (select name from public.departments where id = ep.department_id)
    when 'location' then (select name from public.locations where id = ep.location_id)
    when 'company' then (select name from public.companies where id = ep.company_id)
    when 'employment_type' then (select label from public.employment_types where key = ep.employment_type_key)
    when 'start_date' then to_char(ep.start_date, 'DD Mon YYYY')
    when 'end_date' then to_char(ep.end_date, 'DD Mon YYYY')
    when 'last_working_date' then to_char(ep.last_working_date, 'DD Mon YYYY')
    when 'manager' then (select full_name from public.people where id = ep.manager_id)
    when 'birth_date' then to_char(pd.birth_date, 'DD Mon YYYY')
    when 'address' then pd.address ->> 'line'
    when 'national_id' then pd.national_id
    when 'bank_account' then nullif(concat_ws(' · ', pd.bank_account ->> 'bank', pd.bank_account ->> 'account_number'), '')
    when 'salary' then (select amount::text || ' ' || currency || ' ' || pay_basis_key from public.compensation_records
                        where employment_period_id = p_period_id and status = 'approved'
                          and effective_date <= current_date and (end_date is null or end_date >= current_date)
                        order by effective_date desc limit 1)
    when 'starter_kit' then null   -- 049
    when 'equipment_held' then (select string_agg(a.asset_tag || coalesce(' ' || a.model, ''), ', ' order by a.asset_tag)
                                from public.asset_assignments aa join public.assets a on a.id = aa.asset_id
                                where aa.person_id = p_person_id and aa.returned_at is null and aa.issued_at is not null)
    else null
  end;
end $$;

/**
 * One send per active recipient of the event: the snapshot of exactly that
 * recipient's fields (sensitive ones only when trusted — otherwise stripped
 * and named), the address resolved now, `missing` when a field or the
 * address is empty. Idempotent per person + event + recipient + occasion.
 */
create or replace function app.raise_handover(
  p_event text, p_person_id uuid, p_company_id uuid, p_period_id uuid, p_plan_id uuid, p_occasion text
) returns int
language plpgsql security definer set search_path = public as $$
declare
  r public.handover_recipients;
  v_fields jsonb;
  v_missing text[];
  v_stripped text[];
  v_to text;
  v_key text;
  v_val text;
  v_label text;
  v_sens text;
  v_n int := 0;
  v_inserted int;
begin
  for r in select * from app.handover_recipients_for(p_company_id) where p_event = any(events) loop
    v_fields := '{}'::jsonb; v_missing := '{}'; v_stripped := '{}';
    foreach v_key in array r.fields loop
      select label, sensitivity into v_label, v_sens from app.handover_fields() where key = v_key;
      if v_label is null then continue; end if;
      if v_sens <> 'plain' and not r.trusted then
        v_stripped := array_append(v_stripped, v_label);
        continue;
      end if;
      v_val := app.handover_value(v_key, p_person_id, p_period_id);
      if v_val is null and v_key in ('starter_kit', 'equipment_held') then
        -- A list that is empty is an answer, not a gap (the kit itself is 049's).
        v_val := 'None';
      end if;
      if v_val is null then
        v_missing := array_append(v_missing, v_label);
      else
        v_fields := v_fields || jsonb_build_object(v_key, jsonb_build_object('label', v_label, 'value', v_val));
      end if;
    end loop;
    v_to := app.handover_address(r, p_period_id, p_company_id);
    if v_to is null then v_missing := array_prepend('Address for ' || r.label, v_missing); end if;
    insert into public.handover_sends
      (person_id, company_id, plan_id, employment_period_id, recipient_id, recipient_label, event, to_email,
       fields, stripped, missing, status, dedupe_key)
    values (p_person_id, p_company_id, p_plan_id, p_period_id, r.id, r.label, p_event, v_to,
            v_fields, v_stripped, v_missing,
            case when cardinality(v_missing) > 0 then 'missing' else 'pending' end,
            'handover:' || p_event || ':' || p_person_id || ':' || r.id || ':' || p_occasion)
    on conflict (dedupe_key) do nothing;
    get diagnostics v_inserted = row_count;
    v_n := v_n + v_inserted;
  end loop;
  return v_n;
end $$;

-- Events: an onboarding plan starting (a hire, from an application or by hand), finishing;
-- an offboarding plan starting; the period becoming former.
create or replace function app.handover_on_plan() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' and new.kind = 'onboarding' then
    perform app.raise_handover('hire_confirmed', new.person_id, new.company_id, new.employment_period_id, new.id, new.id::text);
  elsif tg_op = 'INSERT' and new.kind = 'offboarding' then
    perform app.raise_handover('departure_scheduled', new.person_id, new.company_id, new.employment_period_id, new.id, new.id::text);
  elsif tg_op = 'UPDATE' and new.kind = 'onboarding' and new.status = 'completed' and old.status <> 'completed' then
    perform app.raise_handover('onboarding_finished', new.person_id, new.company_id, new.employment_period_id, new.id, new.id::text || ':' || coalesce(new.completed_at::text, ''));
  elsif tg_op = 'UPDATE' and new.kind = 'offboarding' and new.status = 'cancelled' and old.status <> 'cancelled' then
    update public.handover_sends set status = 'cancelled' where plan_id = new.id and status in ('pending', 'missing');
  end if;
  return new;
end $$;
create trigger t9_handover after insert or update on public.plans for each row execute function app.handover_on_plan();

create or replace function app.handover_on_period() returns trigger
language plpgsql security definer set search_path = public as $$
declare v_plan uuid;
begin
  if new.status = 'former' and old.status <> 'former' then
    select id into v_plan from public.plans where employment_period_id = new.id and kind = 'offboarding' order by created_at desc limit 1;
    perform app.raise_handover('marked_former', new.person_id, new.company_id, new.id, v_plan, new.id::text);
  end if;
  return new;
end $$;
create trigger t9_handover after update on public.employment_periods for each row execute function app.handover_on_period();

-- ------------------------------------------------------------ 4. by hand
create or replace function app.can_work_send(p_id uuid) returns public.handover_sends
language plpgsql stable security definer set search_path = public as $$
declare s public.handover_sends;
begin
  if app.current_person_id() is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  select * into s from public.handover_sends where id = p_id;
  if not found then
    raise exception 'Send not found.' using errcode = 'P0002';
  end if;
  if not app.has_capability(s.company_id, 'tasks.assign') then
    raise exception 'Working the handover needs tasks.assign in this company.' using errcode = '42501';
  end if;
  return s;
end $$;

/** Rebuild the snapshot from the record as it is now and queue it again — "fill it and resend". */
create or replace function public.resend_handover(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  s public.handover_sends := app.can_work_send(p_id);
  r public.handover_recipients;
  v_fields jsonb := '{}'::jsonb;
  v_missing text[] := '{}';
  v_stripped text[] := '{}';
  v_key text; v_val text; v_label text; v_sens text; v_to text;
begin
  select * into r from public.handover_recipients where id = s.recipient_id;
  if not found then
    raise exception 'The recipient is no longer configured; add them again under Settings → Handover.' using errcode = '22023';
  end if;
  foreach v_key in array r.fields loop
    select label, sensitivity into v_label, v_sens from app.handover_fields() where key = v_key;
    if v_label is null then continue; end if;
    if v_sens <> 'plain' and not r.trusted then v_stripped := array_append(v_stripped, v_label); continue; end if;
    v_val := app.handover_value(v_key, s.person_id, s.employment_period_id);
    if v_val is null and v_key in ('starter_kit', 'equipment_held') then v_val := 'None'; end if;
    if v_val is null then
      v_missing := array_append(v_missing, v_label);
    else
      v_fields := v_fields || jsonb_build_object(v_key, jsonb_build_object('label', v_label, 'value', v_val));
    end if;
  end loop;
  v_to := app.handover_address(r, s.employment_period_id, s.company_id);
  if v_to is null then v_missing := array_prepend('Address for ' || r.label, v_missing); end if;
  update public.handover_sends
     set fields = v_fields, stripped = v_stripped, missing = v_missing, to_email = v_to,
         status = case when cardinality(v_missing) > 0 then 'missing' else 'pending' end,
         error = null, attempts = 0, sent_at = null, marked_by = null, recipient_label = r.label
   where id = p_id;
  return jsonb_build_object('id', p_id, 'status', case when cardinality(v_missing) > 0 then 'missing' else 'pending' end, 'missing', to_jsonb(v_missing));
end $$;

/** HR sent it another way: green, with who said so. */
create or replace function public.mark_handover_sent(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s public.handover_sends := app.can_work_send(p_id);
begin
  update public.handover_sends set status = 'manual', marked_by = app.current_person_id(), sent_at = now(), error = null where id = s.id;
  return jsonb_build_object('id', s.id, 'status', 'manual');
end $$;

/** A failed one back to the queue. */
create or replace function public.retry_handover(p_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare s public.handover_sends := app.can_work_send(p_id);
begin
  if s.status <> 'failed' then
    raise exception 'Only a failed send is retried; use Resend to rebuild it.' using errcode = '22023';
  end if;
  update public.handover_sends set status = 'pending', attempts = 0, error = null where id = s.id;
  return jsonb_build_object('id', s.id, 'status', 'pending');
end $$;

revoke all on function public.resend_handover(uuid) from public, anon;
revoke all on function public.mark_handover_sent(uuid) from public, anon;
revoke all on function public.retry_handover(uuid) from public, anon;
grant execute on function public.resend_handover(uuid) to authenticated, service_role;
grant execute on function public.mark_handover_sent(uuid) to authenticated, service_role;
grant execute on function public.retry_handover(uuid) to authenticated, service_role;

-- ------------------------------------------------------------ 5. self-tick
-- "Handover sent to accounting and IT" / "Departure sent to accounting"
-- tick when every send of the plan's event is green (sent or manual).
create or replace function app.tick_handover(p_plan_id uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_kind text; v_event text; v_key text;
begin
  if p_plan_id is null then return; end if;
  select kind into v_kind from public.plans where id = p_plan_id;
  if v_kind = 'onboarding' then v_event := 'hire_confirmed'; v_key := 'handover';
  else v_event := 'departure_scheduled'; v_key := 'handover_out'; end if;
  if exists (select 1 from public.handover_sends where plan_id = p_plan_id and event = v_event)
     and not exists (select 1 from public.handover_sends where plan_id = p_plan_id and event = v_event and status not in ('sent', 'manual', 'cancelled')) then
    update public.plan_tasks set status = 'done', done_at = now(), done_by = coalesce(app.current_person_id(), done_by)
      where plan_id = p_plan_id and task_key = v_key and status in ('open', 'blocked');
  end if;
end $$;
create or replace function app.handover_send_tick() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform app.tick_handover(new.plan_id);
  return new;
end $$;
create trigger tick after insert or update on public.handover_sends for each row execute function app.handover_send_tick();

-- ------------------------------------------------------------ 6. IT requests
create or replace function app.notify_it_request() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_who text := app.person_name(new.person_id);
  v_it uuid := (select person_id from public.workflow_owners where company_id = new.company_id and role_key = 'it_owner');
  v_hr uuid := (select person_id from public.workflow_owners where company_id = new.company_id and role_key = 'hr_owner');
  v_it_mail text := (select it_notification_email from public.companies where id = new.company_id);
begin
  if tg_op = 'INSERT' then
    if v_it is not null and v_it is distinct from new.requested_by then
      perform app.notify(v_it, new.company_id, 'it.requested', 'IT request for ' || v_who || ': ' || new.title,
        coalesce('Due ' || to_char(new.due_at, 'DD Mon YYYY'), 'No due date') || ' · ' || new.kind,
        '/companies/' || new.company_id || '?tab=equipment', 'it_request', new.id, 'it.requested:' || new.id);
      if v_it_mail is not null then
        update public.notifications set email_to = v_it_mail, email_status = 'pending' where dedupe_key = 'it.requested:' || new.id || ':' || v_it;
      end if;
    end if;
    return new;
  end if;
  if new.status is not distinct from old.status then return new; end if;
  if new.status = 'blocked' and v_hr is not null then
    perform app.notify(v_hr, new.company_id, 'it.blocked', 'IT request blocked for ' || v_who || ': ' || new.title,
      coalesce(new.blocked_reason, ''), '/companies/' || new.company_id || '?tab=equipment', 'it_request', new.id, 'it.blocked:' || new.id || ':' || now(), true);
  elsif new.status = 'done' and new.requested_by is not null then
    perform app.notify(new.requested_by, new.company_id, 'it.done', 'IT request done for ' || v_who || ': ' || new.title,
      'by ' || app.person_name(coalesce(new.assignee_id, app.current_person_id())), '/people/' || new.person_id, 'it_request', new.id, 'it.done:' || new.id);
  end if;
  return new;
end $$;
create trigger t9_notify after insert or update on public.it_requests for each row execute function app.notify_it_request();
