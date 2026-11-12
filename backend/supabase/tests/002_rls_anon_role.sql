-- Row-level security: the anon role.
--
-- The negative cases are the point. Several tables in this schema have RLS
-- enabled with no policy for anon, or no table grant at all. Both fail closed,
-- and both fail silently during development, so they are pinned down here.
--
-- These tests distinguish missing GRANT (permission denied) from an enabled
-- table grant filtered by RLS (zero rows).
--
-- Run with: npx supabase test db

begin;

select plan(8);

-- ---------------------------------------------------------------------------
-- anon has no access to any per-user table
-- ---------------------------------------------------------------------------

-- Make the table readable at the SQL privilege layer inside this transaction
-- so this assertion exercises the owner-only RLS policy on both Supabase's
-- local stack and the plain-PostgreSQL CI harness. The grant and fixture are
-- rolled back with this test file.
with fixture as (
  select gen_random_uuid() as id
)
insert into auth.users (
  instance_id,
  id,
  aud,
  role,
  email,
  encrypted_password,
  email_confirmed_at,
  created_at,
  updated_at,
  raw_app_meta_data,
  raw_user_meta_data
)
select
  '00000000-0000-0000-0000-000000000000',
  fixture.id,
  'authenticated',
  'authenticated',
  'anon-rls-' || fixture.id::text || '@example.invalid',
  extensions.crypt('test', extensions.gen_salt('bf', 4)),
  now(),
  now(),
  now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  '{"username":"anon_rls_test"}'::jsonb
from fixture;

grant select on table public.profiles to anon;

set local role anon;

select is(
  (select count(*)::integer from public.profiles),
  0,
  'anon cannot read a profile row even when SELECT is granted, due to owner RLS'
);

select throws_ok(
  $$select count(*) from public.notifications$$,
  '42501',
  null,
  'anon cannot read notifications'
);

select throws_ok(
  $$select count(*) from public.user_point_ledger$$,
  '42501',
  null,
  'anon cannot read the point ledger'
);

select throws_ok(
  $$select count(*) from public.user_daily_quests$$,
  '42501',
  null,
  'anon cannot read daily quest assignments'
);

select throws_ok(
  $$select count(*) from public.admin_audit_log$$,
  '42501',
  null,
  'anon cannot read the admin audit log'
);

select throws_ok(
  $$select count(*) from public.report_review_events$$,
  '42501',
  null,
  'anon cannot read report review events'
);

select throws_ok(
  $$select count(*) from public.admin_sessions$$,
  '42501',
  null,
  'anon cannot read admin sessions'
);

-- The published module catalog is deliberately world-readable: the training
-- page has to render before anyone signs in. Nothing that asserts on RLS may be
-- appended below this line.
reset role;

select ok(
  (
    select count(*) > 0
    from public.modules
    where is_active = true and is_published = true
  ),
  'the published module catalog is readable without a session'
);

select * from finish();
rollback;
