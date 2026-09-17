-- 0065_can_sign.sql
-- Whether a person can put their name to anything in the app at all.
--
-- 14 of 42 people have no login, and 11 of them hold equipment. Asking one of
-- them for a laptop back leaves a handover nobody can ever sign: the form waits
-- on a person who cannot reach it.
--
-- The act still works — another IT or HR person receives the thing on the
-- company's behalf, which is what actually happens when somebody walks a laptop
-- to the desk — and the signature says exactly that rather than pretending the
-- holder signed. But whoever starts the recall should know before they sign,
-- not discover it when the row sits there for a month.
--
-- Security definer because people.user_id is not something an ordinary reader
-- gets to see, and this answers one yes/no question about it and nothing else.
create or replace function public.person_can_sign(p_person_id uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.people
                 where id = p_person_id and user_id is not null and archived_at is null)
$$;
grant execute on function public.person_can_sign(uuid) to authenticated;
