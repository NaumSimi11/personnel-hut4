-- 0124: a buddy on every onboarding checklist (board card C3).
--
-- The default onboarding checklist (every company uses it until it keeps its
-- own copy) gains one line: name a buddy before the first day. The hiring
-- manager owns it, as they own the team introduction. A company with its own
-- copy gets the line too. Checklists already running keep their lines; new
-- ones carry the buddy. HR can still edit or retire it in Company Settings →
-- Checklists.

begin;

insert into public.template_tasks
  (template_id, key, title, description, default_owner_role, phase_key, due_offset_days, critical, requires_evidence, sort_order)
select t.id, 'buddy', 'Buddy assigned',
       'A colleague who shows the new hire around and answers questions in the first weeks.',
       'manager', 'before_start', -2, false, false, 85
  from public.task_templates t
 where t.kind = 'onboarding'
   and not exists (select 1 from public.template_tasks x
                    where x.template_id = t.id and x.key = 'buddy' and x.archived_at is null);

commit;
