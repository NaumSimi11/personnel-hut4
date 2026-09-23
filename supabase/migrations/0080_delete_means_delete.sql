-- 0080_delete_means_delete.sql
-- Deleting a mistake, archiving history (plan 063).
--
-- The maintainer, looking at the hiring pages: "i think we have this but i
-- can't see this is planned well" — and he is right. Deleting a job lives on
-- the company page and on one list; a policy can only be archived; a candidate
-- can only be archived. Three different answers to one question.
--
-- One rule instead, the one 0071 and 0074 already follow:
--
--     Delete is for a mistake. Archive is for history.
--     A thing may be deleted only while nothing has happened to it.
--
-- A job goes while nothing was received (0003's NO ACTION says so). An
-- application goes while nothing was recorded against it (0074). This adds the
-- two that were missing, with the same shape and the same refusals in words.
--
-- Both are spelled out rather than left to the foreign keys, for the reason
-- 0074 gave: the keys do not protect what cascades. `candidate_files` and
-- `candidate_notes` both CASCADE, so deleting one imported candidate would
-- take their CV and their history with them without a word — and there are
-- 1,756 imported notes to lose.

-- ------------------------------------------------------------ delete_policy
-- A policy goes while nobody has agreed to it. Once somebody has, the
-- acknowledgement is the record that they read it, and deleting the policy
-- would leave that record pointing at nothing — so archiving is the only way
-- out, which is what `archive_policy` has always been for.
--
-- Returns the storage path so the caller can remove the file it just orphaned:
-- the object lives in Storage, which SQL has no business reaching into.
create or replace function public.delete_policy(p_policy_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_policy record;
  v_acks int;
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  select * into v_policy from public.policies where id = p_policy_id for update;
  if not found then
    raise exception 'That policy no longer exists.' using errcode = '22023';
  end if;
  if not app.can_publish_policy(v_policy.company_id) then
    raise exception 'Deleting needs policies.publish in this company (holding-wide: platform admin).'
      using errcode = '42501';
  end if;
  select count(*) into v_acks from public.policy_acknowledgements where policy_id = p_policy_id;
  if v_acks > 0 then
    raise exception '% % already agreed to "%". Archive it instead, so their record still means something.',
      v_acks, case when v_acks = 1 then 'person has' else 'people have' end, v_policy.title
      using errcode = '22023';
  end if;

  delete from public.policies where id = p_policy_id;
  -- What "all policies acknowledged" means has just changed for this company.
  perform app.retick_policies_for(v_policy.company_id);
  return jsonb_build_object('deleted', true, 'title', v_policy.title, 'storage_path', v_policy.storage_path);
end $$;

-- ------------------------------------------------------------ update_policy
-- Fixing a policy in place, which HR needs for the ordinary case of something
-- missing or mistyped.
--
-- The title and the summary are how a policy is *referred to* — the line in
-- the welcome note, the heading in the list — and may be corrected at any
-- time. The body is what people agree to, so it may be edited freely while the
-- policy is a draft and never afterwards: a published policy's text changes
-- through `publish_policy`, which bumps the version, and the acknowledgements
-- record the version somebody read. Silently rewriting agreed text under an
-- unchanged version number is the one thing this must not allow.
create or replace function public.update_policy(p_policy_id uuid, p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_policy record;
  v_title text := nullif(btrim(coalesce(p->>'title', '')), '');
  v_summary text := nullif(btrim(coalesce(p->>'summary', '')), '');
  v_body text := nullif(btrim(coalesce(p->>'body', '')), '');
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  select * into v_policy from public.policies where id = p_policy_id for update;
  if not found then
    raise exception 'That policy no longer exists.' using errcode = '22023';
  end if;
  if not app.can_publish_policy(v_policy.company_id) then
    raise exception 'Editing needs policies.publish in this company (holding-wide: platform admin).'
      using errcode = '42501';
  end if;
  if v_policy.status = 'archived' then
    raise exception 'An archived policy is history. Create a new one instead.' using errcode = '22023';
  end if;
  if p ? 'title' and v_title is null then
    raise exception 'A policy needs a title.' using errcode = '22023';
  end if;
  if v_title is not null and length(v_title) > 200 then
    raise exception 'Keep the title to 200 characters or fewer.' using errcode = '22023';
  end if;
  if v_summary is not null and length(v_summary) > 500 then
    raise exception 'Keep the summary to 500 characters or fewer — it is one line in the welcome note.'
      using errcode = '22023';
  end if;
  if p ? 'body' and v_policy.status = 'published' and v_body is distinct from v_policy.body then
    raise exception 'This policy is published, so its text changes by publishing a new version — that is what people''s acknowledgements point at.'
      using errcode = '22023';
  end if;

  perform set_config('app.policy_transition', 'on', true);
  update public.policies
     set title = coalesce(v_title, title),
         summary = case when p ? 'summary' then v_summary else summary end,
         body = case when p ? 'body' and status = 'draft' then v_body else body end
   where id = p_policy_id;
  perform set_config('app.policy_transition', 'off', true);
  return jsonb_build_object('id', p_policy_id);
end $$;

-- --------------------------------------------------------- delete_candidate
-- A candidate goes while they are nothing but a name. An application is
-- somebody's history with this holding; a note is what we thought of them; a
-- file is their CV. Any of those and the record stays, archived — which is
-- what the archive has always been for, and what keeps the contact rule (0067)
-- meaning something: a person who asked never to be contacted must not be
-- forgotten, or they will be sourced again next week.
create or replace function public.delete_candidate(p_candidate_id uuid) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_me uuid := app.current_person_id();
  v_cand record;
  v_apps int;
  v_notes int;
  v_files int;
begin
  if v_me is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  select * into v_cand from public.candidates where id = p_candidate_id for update;
  if not found then
    raise exception 'That candidate no longer exists.' using errcode = '22023';
  end if;
  if not app.can_source_candidates() then
    raise exception 'Deleting a candidate needs "Work the talent pool".' using errcode = '42501';
  end if;
  if v_cand.do_not_contact then
    raise exception '% asked never to be contacted again. That has to be remembered, or they will be sourced afresh next week. Archive them instead.',
      v_cand.full_name using errcode = '22023';
  end if;

  select count(*) into v_apps from public.applications where candidate_id = p_candidate_id;
  if v_apps > 0 then
    raise exception '% has % on record. Archive them instead.',
      v_cand.full_name,
      case when v_apps = 1 then 'an application' else v_apps || ' applications' end
      using errcode = '22023';
  end if;
  select count(*) into v_notes from public.candidate_notes where candidate_id = p_candidate_id;
  if v_notes > 0 then
    raise exception 'There % on %. Archive them instead, so it is not lost.',
      case when v_notes = 1 then 'is a note' else 'are ' || v_notes || ' notes' end,
      v_cand.full_name using errcode = '22023';
  end if;
  select count(*) into v_files from public.candidate_files where candidate_id = p_candidate_id;
  if v_files > 0 then
    raise exception '% has % on file. Archive them instead.',
      v_cand.full_name,
      case when v_files = 1 then 'a document' else v_files || ' documents' end
      using errcode = '22023';
  end if;

  delete from public.candidates where id = p_candidate_id;
  return jsonb_build_object('deleted', true, 'name', v_cand.full_name);
end $$;

-- ---------------------------------------------------------------- grants
revoke all on function public.delete_policy(uuid), public.update_policy(uuid, jsonb),
  public.delete_candidate(uuid) from public, anon;
grant execute on function public.delete_policy(uuid), public.update_policy(uuid, jsonb),
  public.delete_candidate(uuid) to authenticated;
