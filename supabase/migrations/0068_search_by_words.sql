-- 0068_search_by_words.sql
-- Searching the talent pool by part of a name (plan 053, follow-up 1 of 052).
--
-- What changed: the name predicate only. 0067 matched the query's whole
-- sorted key as a substring of the candidate's sorted key
-- (c.name_key like '%' || v_name_key || '%'), so a partial multi-word query
-- matched only when its words happened to be a contiguous run of the
-- candidate's sorted words: "E2E Pool" missed "E2E Pool Person", "Mar Pet"
-- missed "Marko Petrov". It is now: every word of the query's key is a
-- word-prefix of some word of the candidate's key, order-free.
--
-- What did not: everything else in search_candidates — the sign-in and
-- capability gates, the email / title / employer / skills ilike, the phone
-- and LinkedIn keys, the source, contact, activity and company filters, the
-- visibility rule, paging, applications_count and the list capped at three.
-- No column, index, type or signature change; app/src/types/database.ts is
-- untouched. app.name_key itself is unchanged: the mirror in candidatePool.ts
-- still sorts, because dedupe is still exact-key.

-- The words of the query key carry no regex metacharacter, so the pattern is
-- built by concatenation and nothing is escaped: name_key lower-cases, folds
-- Latin diacritics, drops bracketed parts and turns every run of non-letters
-- ([^[:alpha:]]+) into a single space, so a word is letters only. [:alpha:]
-- is locale-aware, so a letter the fold table does not cover — Cyrillic, for
-- one; the 0067 smoke asserts "Петар Петров" stays Cyrillic — survives into
-- the key. That is still a letter, never a metacharacter, and words are
-- separated by single spaces and are never empty, so '(^| )' || w stays a
-- literal word-prefix test.
create or replace function public.search_candidates(p jsonb) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare
  v_q text := nullif(trim(coalesce(p->>'q', '')), '');
  v_like text;
  v_name_key text;
  v_words text[];
  v_phone_key text;
  v_linkedin_key text;
  v_source text := nullif(p->>'source_key', '');
  v_contact text := coalesce(nullif(p->>'contact', ''), 'any');
  v_activity text := coalesce(nullif(p->>'activity', ''), 'any');
  v_company uuid := nullif(p->>'company_id', '')::uuid;
  v_archived boolean := coalesce((p->>'include_archived')::boolean, false);
  v_limit int := least(greatest(coalesce((p->>'limit')::int, 50), 1), 100);
  v_offset int := greatest(coalesce((p->>'offset')::int, 0), 0);
  v_total int;
  v_rows jsonb;
begin
  if app.current_person_id() is null then
    raise exception 'Sign in to continue.' using errcode = '42501';
  end if;
  if not app.can_source_candidates() then
    raise exception 'The talent pool needs the "Work the talent pool" capability.' using errcode = '42501';
  end if;
  if v_contact not in ('any', 'ok', 'do_not_contact', 'wait') then
    raise exception 'Unknown contact filter "%".', v_contact using errcode = '22023';
  end if;
  if v_activity not in ('any', '90d', '1y', 'older') then
    raise exception 'Unknown activity filter "%".', v_activity using errcode = '22023';
  end if;
  if v_q is not null then
    v_like := '%' || replace(replace(replace(v_q, '\', '\\'), '%', '\%'), '_', '\_') || '%';
    v_name_key := app.name_key(v_q);
    if v_name_key is not null then
      v_words := regexp_split_to_array(v_name_key, ' ');
    end if;
    v_phone_key := app.phone_key(v_q);
    v_linkedin_key := app.linkedin_key(v_q);
  end if;

  with f as (
    select c.*
    from public.candidates c
    where (v_archived or c.archived_at is null)
      and (v_q is null
           -- Every query word a word-prefix of the name key, order-free.
           or (v_words is not null and (select bool_and(c.name_key ~ ('(^| )' || w)) from unnest(v_words) w))
           or c.email::text ilike v_like
           or (v_phone_key is not null and c.phone_key = v_phone_key)
           or (v_linkedin_key is not null and c.linkedin_key = v_linkedin_key)
           or c.current_title ilike v_like
           or c.current_employer ilike v_like
           or exists (select 1 from unnest(c.skills) s where s ilike v_like))
      and (v_source is null or c.source_key = v_source)
      -- "wait" is the assert_contactable rule (contactState in candidatePool.ts
      -- mirrors it): a contact-later record whose date has passed is contactable.
      and (v_contact = 'any'
           or (v_contact = 'ok' and not c.do_not_contact
               and not (c.contact_later and (c.contact_again_after is null or c.contact_again_after > current_date)))
           or (v_contact = 'do_not_contact' and c.do_not_contact)
           or (v_contact = 'wait' and c.contact_later
               and (c.contact_again_after is null or c.contact_again_after > current_date)))
      and (v_activity = 'any'
           or (v_activity = '90d' and c.last_activity_at >= now() - interval '90 days')
           or (v_activity = '1y' and c.last_activity_at >= now() - interval '1 year')
           or (v_activity = 'older' and c.last_activity_at < now() - interval '1 year'))
      and (v_company is null or exists (
             select 1 from public.applications a
             where a.candidate_id = c.id and a.company_id = v_company
               and app.has_capability(a.company_id, 'candidates.view')))
  ), page as (
    select * from f order by last_activity_at desc, full_name limit v_limit offset v_offset
  )
  select (select count(*) from f),
         coalesce((select jsonb_agg(jsonb_build_object(
             'id', pg.id, 'full_name', pg.full_name, 'email', pg.email, 'phone', pg.phone,
             'current_title', pg.current_title, 'current_employer', pg.current_employer,
             'location', pg.location, 'skills', to_jsonb(pg.skills),
             'source_key', pg.source_key,
             'source_label', (select cs.label from public.candidate_sources cs where cs.key = pg.source_key),
             'provider', pg.provider,
             'do_not_contact', pg.do_not_contact, 'contact_later', pg.contact_later,
             'contact_again_after', pg.contact_again_after,
             'last_activity_at', pg.last_activity_at, 'archived_at', pg.archived_at,
             'files_count', (select count(*) from public.candidate_files cf where cf.candidate_id = pg.id),
             -- The count and the list share one visibility rule; only the list is capped.
             'applications_count', (select count(*) from public.applications a
                                     where a.candidate_id = pg.id and app.has_capability(a.company_id, 'candidates.view')),
             'applications', coalesce((
               select jsonb_agg(jsonb_build_object(
                        'id', a.id, 'job_id', a.job_id, 'job_title', j.title,
                        'company_id', a.company_id, 'company_name', co.name,
                        'stage_key', a.stage_key, 'received_at', a.received_at)
                      order by a.received_at desc)
               from (select * from public.applications a
                      where a.candidate_id = pg.id and app.has_capability(a.company_id, 'candidates.view')
                      order by a.received_at desc limit 3) a
               join public.jobs j on j.id = a.job_id
               join public.companies co on co.id = a.company_id), '[]'::jsonb))
           order by pg.last_activity_at desc, pg.full_name) from page pg), '[]'::jsonb)
    into v_total, v_rows;
  return jsonb_build_object('total', v_total, 'rows', v_rows);
end $$;

-- create or replace keeps the existing ACL; re-declared so a fresh database
-- built from the migrations is identical to one that ran 0067 first.
revoke all on function public.search_candidates(jsonb) from public, anon;
grant execute on function public.search_candidates(jsonb) to authenticated;
