-- 0031_avatars.sql
-- Profile photos (plan 040). A public bucket like company logos — a photo is
-- shown next to the name everywhere, so it is fetched by plain URL; the
-- object path carries a random id, so nothing is guessable. Writes follow
-- the people table: the person themselves, or whoever may edit their record
-- (app.can_edit_person). people.avatar_url stores the object path; the app
-- builds the public URL. Objects live at {person_id}/{uuid}.{ext}.

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('avatars', 'avatars', true, 2097152, array['image/png', 'image/jpeg', 'image/webp'])
on conflict (id) do nothing;

create or replace function app.avatar_object_person(object_name text) returns uuid
language sql immutable as $$
  select case when split_part(object_name, '/', 1) ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
              then split_part(object_name, '/', 1)::uuid end
$$;

create or replace function app.can_write_avatar(object_name text) returns boolean
language sql stable security definer set search_path = public as $$
  select app.avatar_object_person(object_name) is not null
     and (app.is_self(app.avatar_object_person(object_name)) or app.can_edit_person(app.avatar_object_person(object_name)))
$$;
grant execute on function app.can_write_avatar(text) to authenticated;

create policy "avatars: public read" on storage.objects
  for select to anon, authenticated using (bucket_id = 'avatars');
create policy "avatars: own or editable insert" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'avatars' and app.can_write_avatar(name));
create policy "avatars: own or editable update" on storage.objects
  for update to authenticated
  using (bucket_id = 'avatars' and app.can_write_avatar(name))
  with check (bucket_id = 'avatars' and app.can_write_avatar(name));
create policy "avatars: own or editable delete" on storage.objects
  for delete to authenticated
  using (bucket_id = 'avatars' and app.can_write_avatar(name));

-- The record side: one function instead of widening the people update
-- policy to self (a person may not edit their own name or email).
create or replace function public.set_avatar(p_person_id uuid, p_path text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_old text;
begin
  if app.current_person_id() is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  if not app.is_self(p_person_id) and not app.can_edit_person(p_person_id) then
    raise exception 'Only the person or someone who may edit their record can change the photo.' using errcode = '42501';
  end if;
  if p_path is not null and (app.avatar_object_person(p_path) is distinct from p_person_id) then
    raise exception 'The photo must be stored under this person''s own folder.';
  end if;
  select avatar_url into v_old from public.people where id = p_person_id;
  update public.people set avatar_url = p_path where id = p_person_id;
  return jsonb_build_object('avatar_url', p_path, 'previous', v_old);
end $$;
revoke all on function public.set_avatar(uuid, text) from public;
grant execute on function public.set_avatar(uuid, text) to authenticated;
