-- shim_supabase.sql — LOCAL TESTING ONLY, never run against a Supabase project.
-- Recreates the pieces of the Supabase platform the migrations rely on
-- (auth schema, auth.uid(), platform roles) so the migrations can be verified
-- on vanilla Postgres. On Supabase these already exist.

create role anon nologin;
create role authenticated nologin;
create role service_role nologin bypassrls;

create schema auth;

create table auth.users (
  id uuid primary key,
  email text unique
);

-- Test stand-ins for Supabase's auth.uid()/auth.jwt(): read session variables
-- that the smoke test sets per simulated user.
create function auth.uid() returns uuid
language sql stable as $$
  select nullif(current_setting('app.test_uid', true), '')::uuid
$$;

create function auth.jwt() returns jsonb
language sql stable as $$
  select coalesce(nullif(current_setting('app.test_jwt', true), '')::jsonb, '{}'::jsonb)
$$;

grant usage on schema auth to anon, authenticated, service_role;
grant execute on function auth.uid() to anon, authenticated, service_role;
grant execute on function auth.jwt() to anon, authenticated, service_role;
grant select on auth.users to authenticated, service_role;

-- Minimal stand-in for Supabase Storage so bucket seeds and storage.objects
-- policies in migrations can be verified locally. Same shape as the platform
-- columns the migrations touch; nothing else.
create schema storage;
create table storage.buckets (
  id text primary key,
  name text not null unique,
  public boolean not null default false,
  file_size_limit bigint,
  allowed_mime_types text[]
);
create table storage.objects (
  id uuid primary key default gen_random_uuid(),
  bucket_id text references storage.buckets(id),
  name text,
  owner uuid,
  metadata jsonb
);
alter table storage.objects enable row level security;
grant usage on schema storage to anon, authenticated, service_role;
grant select on storage.buckets to anon, authenticated, service_role;
grant all on storage.objects to anon, authenticated, service_role;
