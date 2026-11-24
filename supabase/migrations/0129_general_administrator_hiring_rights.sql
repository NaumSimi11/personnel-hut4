-- 0129 — the General Administrator can do the hiring work v2.2 gives it (24 Nov).
--
-- 0120 made the role for access, connections and the onboarding checklist.
-- Since 18 Nov it also carries HR's hiring work (Workflow v2.2): approving
-- hiring requests and offers, drafting offers, confirming the hire, Did not
-- start and the first day. No access role held "Approve hiring requests" or
-- "Approve offers", so only platform admins could approve.
--
-- Added: jobs.view, jobs.approve, candidates.view, candidates.review,
-- offer.approve, employment.edit (each one's prerequisite included). Grants
-- made from the role get the same, so a holder never lags the role.

begin;

update public.permission_presets
   set description = 'Administration, hiring approvals and onboarding: approves hiring requests and offers, confirms hires, runs the new-hire checklist, company access and connections'
 where name = 'General Administrator' and company_id is null;

insert into public.preset_capabilities (preset_id, capability_key)
select p.id, c.key
  from public.permission_presets p
 cross join (values
   ('jobs.view'), ('jobs.approve'),
   ('candidates.view'), ('candidates.review'), ('offer.approve'),
   ('employment.edit')
 ) as c(key)
 where p.name = 'General Administrator' and p.company_id is null
on conflict do nothing;

insert into public.grant_capabilities (grant_id, capability_key)
select g.id, pc.capability_key
  from public.access_grants g
  join public.permission_presets p on p.id = g.source_preset_id and p.name = 'General Administrator' and p.company_id is null
  join public.preset_capabilities pc on pc.preset_id = p.id
on conflict do nothing;

commit;
