-- Row-level security: the authenticated role.
--
-- Two different failure shapes are asserted here, and confusing them is the
-- usual reason an RLS test suite gives a false green:
--
--   * A row the policy excludes is silently filtered. An UPDATE aimed at
--     another user's report succeeds and changes nothing. The only way to see
--     it is to assert on row counts.
--   * A field the guard trigger protects raises. An owner editing their own
--     report's review_status passes RLS and then trips the trigger.
--
-- Run with: npx supabase test db

begin;

select plan(16);

-- ---------------------------------------------------------------------------
-- Fixtures: two users, so cross-user isolation is testable
-- ---------------------------------------------------------------------------

create temporary table fixture_user (
  ordinal smallint primary key,
  user_id uuid not null
);

insert into fixture_user (ordinal, user_id)
values
  (1, gen_random_uuid()),
  (2, gen_random_uuid());

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
  fixture.user_id,
  'authenticated',
  'authenticated',
  'rls-test-' || fixture.ordinal::text || '@example.invalid',
  extensions.crypt('rls-test-password', extensions.gen_salt('bf', 4)),
  now(),
  now(),
  now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  jsonb_build_object('username', 'rls_test_' || fixture.ordinal::text)
from fixture_user as fixture;

insert into public.profiles (id, username, email)
select
  fixture.user_id,
  'rls_test_' || fixture.ordinal::text,
  'rls-test-' || fixture.ordinal::text || '@example.invalid'
from fixture_user as fixture
on conflict (id) do nothing;

-- prepare_practice_report forces new.user_id := auth.uid(), so each report has
-- to be inserted while the claims name its owner. The role stays the test
-- runner (which bypasses RLS) and only the claims change.
select set_config(
  'request.jwt.claims',
  json_build_object('sub', (select user_id::text from fixture_user where ordinal = 1))::text,
  true
);

insert into public.practice_reports (
  source, title, category, channel, pattern, evidence, why_risky
)
values (
  'manual',
  'Report owned by user one',
  'SMS phishing',
  'Text message',
  'Urgency',
  'Observed evidence for the user one fixture row.',
  'Urgency applies time pressure to the reader.'
);

select set_config(
  'request.jwt.claims',
  json_build_object('sub', (select user_id::text from fixture_user where ordinal = 2))::text,
  true
);

insert into public.practice_reports (
  source, title, category, channel, pattern, evidence, why_risky
)
values (
  'manual',
  'Report owned by user two',
  'SMS phishing',
  'Text message',
  'Authority',
  'Observed evidence for the user two fixture row.',
  'An authority claim replaces independent verification.'
);

-- Scoped to the fixture users. An unscoped count would assert against every
-- report in the database and pass only on an empty one.
select is(
  (
    select count(*)::integer
    from public.practice_reports as report
    where report.user_id in (select fixture.user_id from fixture_user as fixture)
  ),
  2,
  'both fixture reports were created under their own owner'
);

-- The assertions below run as authenticated, so the fixture needs to be
-- readable by that role. Temporary tables are session-local but still
-- permission-checked, and these were created by the test runner.
grant select on fixture_user to authenticated;

-- Claims for user 1 are set here, while still running as the test runner, so no
-- post-switch statement has to read a table authenticated may not reach.
select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', (select user_id::text from fixture_user where ordinal = 1),
    'role', 'authenticated',
    'is_anonymous', false
  )::text,
  true
);

-- ---------------------------------------------------------------------------
-- Acting as user 1
-- ---------------------------------------------------------------------------

set local role authenticated;

-- profiles_select_own: one row, their own.
select is(
  (select count(*)::integer from public.profiles),
  1,
  'authenticated reads exactly one profile: their own'
);

select is(
  (select (select username from public.profiles)::text),
  'rls_test_1',
  'the visible profile is the caller own row'
);

-- profiles_update_own filters the other row out, so the UPDATE is a silent
-- no-op rather than an error.
update public.profiles
set username = 'hijacked'
where id = (select user_id from fixture_user where ordinal = 2);

select is(
  (
    select count(*)::integer
    from public.profiles
    where username = 'hijacked'
  ),
  0,
  'authenticated cannot rename another profile'
);

-- Own row passes RLS, then the guard trigger rejects the balance change.
select throws_ok(
  $$
    update public.profiles
    set points = 999999
    where id = (select user_id from fixture_user where ordinal = 1)
  $$,
  '42501',
  'PROFILE_POINTS_IMMUTABLE',
  'authenticated cannot move their own point balance directly'
);

-- A forged award, no grant on the table at all.
select throws_ok(
  $$
    insert into public.user_point_ledger (user_id, amount, reason, source_type, source_id)
    values (
      (select user_id from fixture_user where ordinal = 1),
      500, 'admin_adjustment', 'manual', 'rls-forged-award'
    )
  $$,
  '42501',
  null,
  'authenticated cannot insert a point ledger row'
);

select throws_ok(
  $$
    insert into public.user_daily_quests (user_id, quest_date, quest_id, target_value, reward_points)
    values (
      (select user_id from fixture_user where ordinal = 1),
      current_date, 'daily-login', 1, 10
    )
  $$,
  '42501',
  null,
  'authenticated cannot insert a daily quest row directly'
);

-- The owner editing their own report passes RLS, then trips the guard trigger
-- on the moderation field.
select throws_ok(
  $$
    update public.practice_reports
    set review_status = 'approved'
    where user_id = (select user_id from fixture_user where ordinal = 1)
  $$,
  '42501',
  'PRACTICE_REPORT_SYSTEM_FIELDS_IMMUTABLE',
  'a report owner cannot self-approve their own report'
);

select throws_ok(
  $$
    update public.practice_reports
    set admin_note = 'self reviewed'
    where user_id = (select user_id from fixture_user where ordinal = 1)
  $$,
  '42501',
  'PRACTICE_REPORT_SYSTEM_FIELDS_IMMUTABLE',
  'a report owner cannot write the reviewer note'
);

select throws_ok(
  $$
    update public.practice_reports
    set signal_score = 99
    where user_id = (select user_id from fixture_user where ordinal = 1)
  $$,
  '42501',
  'PRACTICE_REPORT_SYSTEM_FIELDS_IMMUTABLE',
  'a report owner cannot inflate the cached signal score'
);

-- Editing user content on their own report is allowed.
update public.practice_reports
set evidence = 'Rewritten evidence by the owner of the row.'
where user_id = (select user_id from fixture_user where ordinal = 1);

select is(
  (
    select count(*)::integer
    from public.practice_reports
    where user_id = (select user_id from fixture_user where ordinal = 1)
      and evidence = 'Rewritten evidence by the owner of the row.'
  ),
  1,
  'a report owner can still edit their own report content'
);

-- The other user row is filtered out of the UPDATE by RLS: no error, no change.
update public.practice_reports
set evidence = 'Attempted cross-account rewrite of a report.'
where user_id = (select user_id from fixture_user where ordinal = 2);

select is(
  (
    select count(*)::integer
    from public.practice_reports
    where evidence = 'Attempted cross-account rewrite of a report.'
  ),
  0,
  'a user cannot edit another user report'
);

select throws_ok(
  $$select count(*) from public.admin_audit_log$$,
  '42501',
  null,
  'authenticated cannot read the admin audit log'
);

select throws_ok(
  $$select count(*) from public.admin_accounts$$,
  '42501',
  null,
  'authenticated cannot read admin accounts'
);

-- The review history carries admin_accounts usernames and moderation notes.
-- It must be as closed as admin_accounts itself, not merely closed to anon.
select throws_ok(
  $$select count(*) from public.report_review_events$$,
  '42501',
  null,
  'authenticated cannot read report review events directly'
);

select throws_ok(
  $$select count(*) from public.admin_sessions$$,
  '42501',
  null,
  'authenticated cannot read admin sessions'
);

-- finish() is pgTAP's own bookkeeping; run it as the role that owns the
-- transaction rather than as authenticated. Nothing that asserts on RLS may be
-- appended below this line: as the table owner it would pass regardless of the
-- policy it appeared to test.
reset role;

select * from finish();
rollback;
