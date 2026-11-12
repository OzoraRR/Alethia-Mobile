-- The two admin write paths that no test covered until now.
--
-- Both shipped broken and were found only by executing them:
--
--   * report_signals had INSERT and DELETE policies for authenticated, and a
--     trigger that recomputes practice_reports.signal_score, but the trigger's
--     UPDATE was rejected by the table's own guard trigger. The signal cache was
--     pinned at 0.
--   * admin_upsert_quest could not compile its body, because quest_type was
--     both a parameter and a column of quest_event_registry.
--
-- Nothing in 001-003 calls either, which is why two rounds of review missed
-- them. This file calls both.
--
-- Run with: npx supabase test db

begin;

select plan(10);

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------

create temporary table fixture_user as
select gen_random_uuid() as user_id;

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data
)
values (
  '00000000-0000-0000-0000-000000000000',
  (select user_id from fixture_user),
  'authenticated',
  'authenticated',
  'admin-path-test@example.invalid',
  extensions.crypt('admin-path-test-password', extensions.gen_salt('bf', 4)),
  now(), now(), now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  '{"username":"admin_path_test"}'::jsonb
);

insert into public.profiles (id, username, email)
select user_id, 'admin_path_test', 'admin-path-test@example.invalid'
from fixture_user
on conflict (id) do nothing;

select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', (select user_id::text from fixture_user),
    'role', 'authenticated',
    'is_anonymous', false
  )::text,
  true
);

-- ---------------------------------------------------------------------------
-- 1. signal_score is a cache the client cannot forge but can move
-- ---------------------------------------------------------------------------

-- prepare_practice_report stamps signal_score = 0, so it starts here regardless
-- of any report_signals history.
insert into public.practice_reports (
  source, title, category, channel, pattern, evidence, why_risky
)
values (
  'manual',
  'Signal path fixture report',
  'SMS phishing',
  'Text message',
  'Urgency',
  'Observed evidence for the signal path fixture.',
  'Urgency applies time pressure to the reader.'
);

select is(
  (
    select report.signal_score
    from public.practice_reports as report
    where report.title = 'Signal path fixture report'
  ),
  0,
  'a new report starts with signal_score 0'
);

-- The client may signal its own report. Before 20260926090000 this raised
-- PRACTICE_REPORT_SYSTEM_FIELDS_IMMUTABLE, because the recompute trigger tripped
-- the moderation guard on its way to setting the cache.
insert into public.report_signals (report_id, user_id)
select report.id, fixture.user_id
from public.practice_reports as report, fixture_user as fixture
where report.title = 'Signal path fixture report';

select is(
  (
    select report.signal_score
    from public.practice_reports as report
    where report.title = 'Signal path fixture report'
  ),
  1,
  'signalling a report moves the cached signal_score to 1'
);

-- A second user signalling the same report is a distinct signal.
insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data
)
values (
  '00000000-0000-0000-0000-000000000000',
  gen_random_uuid(),
  'authenticated',
  'authenticated',
  'admin-path-test-2@example.invalid',
  extensions.crypt('admin-path-test-password', extensions.gen_salt('bf', 4)),
  now(), now(), now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  '{"username":"admin_path_test_2"}'::jsonb
);

insert into public.profiles (id, username, email)
select
  auth_user.id,
  'admin_path_test_2',
  'admin-path-test-2@example.invalid'
from auth.users as auth_user
where auth_user.email = 'admin-path-test-2@example.invalid'
on conflict (id) do nothing;

insert into public.report_signals (report_id, user_id)
select report.id, profile.id
from public.practice_reports as report
join public.profiles as profile
  on profile.email = 'admin-path-test-2@example.invalid'
where report.title = 'Signal path fixture report';

select is(
  (
    select report.signal_score
    from public.practice_reports as report
    where report.title = 'Signal path fixture report'
  ),
  2,
  'a second distinct signal moves the cache to 2'
);

-- The same user signalling twice is one signal: the primary key is
-- (report_id, user_id).
select throws_ok(
  $$
    insert into public.report_signals (report_id, user_id)
    select report.id, fixture.user_id
    from public.practice_reports as report, fixture_user as fixture
    where report.title = 'Signal path fixture report'
  $$,
  '23505',
  null,
  'the same user cannot signal the same report twice'
);

-- The cache follows a delete, which is the other half of the trigger pair.
delete from public.report_signals
where user_id = (select id from public.profiles where email = 'admin-path-test-2@example.invalid');

select is(
  (
    select report.signal_score
    from public.practice_reports as report
    where report.title = 'Signal path fixture report'
  ),
  1,
  'deleting a signal moves the cache back to 1'
);

-- ---------------------------------------------------------------------------
-- 2. admin_upsert_quest compiles and writes
-- ---------------------------------------------------------------------------

-- A real admin account and session, so the token gate is satisfied and what is
-- under test is the body: whether it compiles at all, and whether the INSERT
-- path produces a row.
-- The id is supplied explicitly. admin_accounts.id is
-- `uuid primary key default gen_random_uuid()`, so a bare INSERT would mint its
-- own value and the admin_sessions row below would reference a uuid that does
-- not exist: admin_sessions_admin_id_fkey.
create temporary table fixture_admin as
select gen_random_uuid() as admin_id;

insert into public.admin_accounts (id, username, password_hash)
select admin_id, 'path_test_admin', extensions.crypt('path-test-password', extensions.gen_salt('bf', 4))
from fixture_admin;

create temporary table fixture_session as
select
  encode(extensions.gen_random_bytes(32), 'hex') as raw_token,
  gen_random_uuid() as session_id,
  (select admin_id from fixture_admin) as admin_id;

insert into public.admin_sessions (id, admin_id, token_hash, expires_at)
select
  session_id,
  admin_id,
  encode(extensions.digest(raw_token, 'sha256'), 'hex'),
  now() + interval '1 hour'
from fixture_session;

-- The RPC is revoked from PUBLIC, so the test has to be the owner to call it.
set local role postgres;

-- The smallint arguments are cast. int4 -> int2 is an assignment cast, not an
-- implicit one, so bare integer literals do not resolve the function at all.
--
-- A junk token is rejected before the body is reached, which is also the check
-- that the function resolves.
select throws_ok(
  $$
    select public.admin_upsert_quest(
      'not-a-real-token', 'path-test-quest', 'Path test quest',
      'Created by the admin write path test.', 'create_report',
      2::smallint, 40, 9::smallint, false
    )
  $$,
  '42501',
  'ADMIN_SESSION_REQUIRED',
  'admin_upsert_quest rejects an invalid session token'
);

-- The create path. Before the parameter rename this raised
-- "column reference quest_type is ambiguous".
select is(
  public.admin_upsert_quest(
    (select raw_token from fixture_session),
    'path-test-quest',
    'Path test quest',
    'Created by the admin write path test.',
    'create_report',
    2::smallint, 40, 9::smallint, false
  ),
  'path-test-quest',
  'admin_upsert_quest creates a quest and returns its id'
);

select is(
  (
    select quest.reward_points
    from public.daily_quests as quest
    where quest.id = 'path-test-quest'
  ),
  40,
  'the created quest carries the reward points it was given'
);

-- The update path, on the same row.
select public.admin_upsert_quest(
  (select raw_token from fixture_session),
  'path-test-quest',
  'Path test quest renamed',
  'Updated by the admin write path test.',
  'create_report',
  3::smallint, 75, 9::smallint, true
);

select is(
  (
    select quest.reward_points
    from public.daily_quests as quest
    where quest.id = 'path-test-quest'
  ),
  75,
  'admin_upsert_quest updates an existing quest'
);

-- An unregistered quest_type is refused by the registry foreign key path.
select throws_ok(
  $$
    select public.admin_upsert_quest(
      (select raw_token from fixture_session),
      'path-test-bad-type', 'Bad type quest',
      'Should never be created.', 'not_a_registered_type',
      1::smallint, 10, 9::smallint, true
    )
  $$,
  '23503',
  'QUEST_TYPE_NOT_REGISTERED',
  'an unregistered quest_type is refused'
);

reset role;

select * from finish();
rollback;
