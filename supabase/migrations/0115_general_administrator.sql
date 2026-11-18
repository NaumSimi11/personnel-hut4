-- 0115: the General Administrator is told of every new hire (board card B5, decision D12).
--
-- D12: a named person in each company, who can be changed. That is a
-- workflow role: each company names its General Administrator under
-- Company Settings → Workflow owners and changes them there; nothing else
-- names a person. The handover sends to a role through workflow_owners
-- already (0041), so the role plus a recipient is the whole change.
--
-- The recipient goes on the holding default and on every company that keeps
-- its own list (Hut4 and Liquiditas today), since an own list replaces the
-- default. Plain fields only, so it needs no trust. A company with no
-- General Administrator named yet gets a send marked missing its address,
-- like any unassigned role.

begin;

insert into public.workflow_roles (key, label) values ('general_admin', 'General Administrator')
on conflict (key) do nothing;

insert into public.handover_recipients (company_id, label, kind, role_key, events, fields, trusted, active, sort_order)
select l.company_id, 'General Administrator', 'role', 'general_admin', array['hire_confirmed'],
       array['name', 'work_email', 'position', 'department', 'location', 'company', 'employment_type', 'start_date'],
       false, true, 40
  from (select null::uuid as company_id
        union
        select distinct company_id from public.handover_recipients where company_id is not null and active) l
 where not exists (select 1 from public.handover_recipients r
                    where r.company_id is not distinct from l.company_id and r.active and r.role_key = 'general_admin');

commit;
