-- The Supabase surface these migrations depend on, stubbed.
--
-- Shared by scripts/verify-migrations.sh and the CI workflow so the two cannot
-- drift. When a stub was missing a column, a clean migration turned into a
-- confusing failure, so each table here carries the columns the migrations
-- actually touch rather than a minimal subset.
--
-- What this does NOT reproduce, and why it matters:
--
--   * auth.users is a stub. The real table has more NOT NULL columns and more
--     defaults, so a fixture insert that succeeds here can still fail on hosted
--     Supabase. That is why the CI job runs the same SQL the local script does
--     rather than treating green as proof against production.
--   * supabase_realtime and pg_cron are absent, so the migrations that touch
--     them take their "unavailable" branches. 20260926080000 in particular
--     cannot add the publication this way, which is exactly the step that has
--     to be run by hand in the Supabase SQL Editor.
--
-- Safe to re-run: everything is if not exists or create or replace.

create schema if not exists auth;
create schema if not exists storage;
create schema if not exists extensions;

-- Roles the RLS tests switch to, and the ones the grants name.
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin bypassrls;
  end if;
end $$;

create extension if not exists pgcrypto with schema extensions;

-- auth.users, trimmed to what the migrations insert into.
create table if not exists auth.users (
  id uuid primary key,
  instance_id uuid,
  aud varchar,
  role varchar,
  email varchar,
  encrypted_password varchar,
  email_confirmed_at timestamptz,
  created_at timestamptz,
  updated_at timestamptz,
  raw_app_meta_data jsonb,
  raw_user_meta_data jsonb
);

-- auth.jwt(), auth.uid() and auth.role() all read the request.jwt.claims GUC,
-- which is what the pgTAP fixtures set. current_setting(..., true) throughout,
-- because a missing GUC must yield null rather than raise.
create or replace function auth.jwt()
returns jsonb language sql stable as $$
  select coalesce(
    nullif(current_setting('request.jwt.claims', true), ''),
    '{}'
  )::jsonb;
$$;

create or replace function auth.uid()
returns uuid language sql stable as $$
  select nullif(
    coalesce(
      current_setting('request.jwt.claim.sub', true),
      auth.jwt() ->> 'sub',
      current_setting('request.jwt.claims', true)::jsonb ->> 'sub'
    ),
    ''
  )::uuid;
$$;

create or replace function auth.role()
returns text language sql stable as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.role', true), ''),
    auth.jwt() ->> 'role',
    current_setting('request.jwt.claims', true)::jsonb ->> 'role'
  );
$$;

grant usage on schema auth to anon, authenticated, service_role;

create or replace function auth.email()
returns text language sql stable as $$
  select auth.jwt() ->> 'email';
$$;

-- Referenced by 20260920000000_profile_avatars.sql.
create table if not exists storage.buckets (
  id text primary key,
  name text not null,
  owner uuid,
  public boolean default false,
  file_size_limit bigint,
  allowed_mime_types text[],
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

create table if not exists storage.objects (
  id uuid primary key default gen_random_uuid(),
  bucket_id text,
  name text,
  owner uuid,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

alter table storage.objects enable row level security;

create or replace function storage.foldername(name text)
returns text[] language sql immutable as $$
  select string_to_array(name, '/');
$$;

grant usage on schema storage to anon, authenticated, service_role;
