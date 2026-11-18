-- 0120: the access roles HR keeps (screenshots of 18 Nov).
--
-- HR keeps Employee, Finance, Hiring Manager, IT, Marketing, No access and
-- Recruiter ("Custom" is not a role: the editor shows it once someone's
-- ticks differ from a role's). General Administrator joins them, with the
-- administration rights and the onboarding tasks; 0115 already tells them of
-- every new hire through Workflow owners.
--
-- Company Director, Company HR and Holding HR leave the list. They are
-- archived, not deleted: nobody holds one in production today, and a grant
-- made from one keeps its ticks and history either way.

begin;

update public.permission_presets
   set archived_at = now()
 where company_id is null
   and name in ('Company Director', 'Company HR', 'Holding HR')
   and archived_at is null;

insert into public.permission_presets (name, description, is_system)
values ('General Administrator', 'Administration and onboarding: company access, connections and the new-hire checklist', true)
on conflict (company_id, name) do update set archived_at = null, description = excluded.description;

insert into public.preset_capabilities (preset_id, capability_key)
select p.id, c.key
  from public.permission_presets p
 cross join (values
   ('access.manage'), ('integration.view'), ('integration.manage'),
   ('people.view'),
   ('tasks.view'), ('tasks.assign'), ('tasks.complete')
 ) as c(key)
 where p.name = 'General Administrator' and p.company_id is null
on conflict do nothing;

commit;
