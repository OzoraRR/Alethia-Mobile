-- Account export and deletion.
--
-- The plpgsql bodies of export_my_data and delete_my_account are not validated
-- at CREATE time, so a misspelled table name compiles cleanly and only fails
-- when somebody calls the function with their own account. Everything here
-- exists to actually invoke them.
--
-- The property that matters most: the reports survive. practice_reports.user_id
-- is ON DELETE CASCADE, so an implementation that deleted the profile first
-- would take every report with it and quietly turn "anonymise" into "delete".
-- That ordering is asserted directly.
--
-- Run with: npx supabase test db

begin;

select plan(22);

-- ---------------------------------------------------------------------------
-- Fixtures: two accounts, so "only the caller's data" is testable
-- ---------------------------------------------------------------------------

create temporary table fixture as
select ordinal, gen_random_uuid() as user_id
from generate_series(1, 2) as ordinal;

-- Read back after set local role authenticated below, which changes current_user
-- to a role with no privileges on a temp table created by the connection user.
grant select on fixture to authenticated;

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data
)
select
  '00000000-0000-0000-0000-000000000000',
  user_id,
  'authenticated',
  'authenticated',
  'gdpr-test-' || ordinal || '@example.invalid',
  extensions.crypt('gdpr-test-password', extensions.gen_salt('bf', 4)),
  now(), now(), now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  jsonb_build_object('username', 'gdpr_test_' || ordinal)
from fixture;

insert into public.profiles (id, username, email)
select user_id, 'gdpr_test_' || ordinal, 'gdpr-test-' || ordinal || '@example.invalid'
from fixture
on conflict (id) do nothing;

-- Set before the report insert: prepare_practice_report raises
-- AUTHENTICATION_REQUIRED without a caller, and these reports are authored.
select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', (select user_id::text from fixture where ordinal = 1),
    'role', 'authenticated',
    'is_anonymous', false
  )::text,
  true
);

-- Three reports for user 1 and one for user 2. User 2's must be untouched by
-- user 1's deletion.
--
-- prepare_practice_report runs `new.user_id := auth.uid()`, so authorship is
-- forced by the caller in the JWT and an insert cannot choose its own owner.
-- Writing the second user's report therefore means being that user for the
-- duration of the insert, not passing their id in the values list. An earlier
-- version of this fixture passed the id and every report silently ended up
-- owned by user 1, which made the "export leaks nothing" assertions pass for the
-- wrong reason and the count come back as 4 instead of 3.
insert into public.practice_reports (
  source, title, category, channel, pattern, evidence, why_risky, defanged_url
)
select
  'manual', 'GDPR fixture 1-' || seed.letter,
  'SMS phishing', 'Text message', 'Urgency',
  'Observed evidence for GDPR fixture ' || seed.letter || '.',
  'Urgency applies time pressure to the reader.',
  'hxxps://example[.]invalid/' || seed.letter
from (values ('A'), ('B'), ('C')) as seed(letter);

select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', (select user_id::text from fixture where ordinal = 2),
    'role', 'authenticated',
    'is_anonymous', false
  )::text,
  true
);

insert into public.practice_reports (
  source, title, category, channel, pattern, evidence, why_risky
)
values (
  'manual', 'GDPR fixture 2-Z', 'SMS phishing', 'Text message', 'Urgency',
  'Observed evidence belonging to the other account.', 'Time pressure.'
);

-- Back to user 1 for the rest of the file.
select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', (select user_id::text from fixture where ordinal = 1),
    'role', 'authenticated',
    'is_anonymous', false
  )::text,
  true
);

set local role authenticated;

-- ---------------------------------------------------------------------------
-- 1. Export
-- ---------------------------------------------------------------------------

select is(
  (public.export_my_data() -> 'account' ->> 'username'),
  'gdpr_test_1',
  'export returns the caller profile'
);

select is(
  jsonb_array_length(public.export_my_data() -> 'reports'),
  3,
  'export returns every report the caller wrote'
);

-- The point of resolving auth.uid() with no parameter: there is no argument to
-- pass, so the other account's report cannot be requested.
select is(
  (
    select count(*)::integer
    from jsonb_array_elements(public.export_my_data() -> 'reports') as exported
    where exported ->> 'title' like 'GDPR fixture 2-%'
  ),
  0,
  'export contains no other account''s data'
);

select is(
  (
    select count(*)::integer
    from jsonb_array_elements(public.export_my_data() -> 'reports') as exported
    where exported ->> 'evidence' like '%other account%'
  ),
  0,
  'export leaks nothing from another account through a shared field'
);

-- The account block strips the id, so the export is not a re-identification
-- vector for whoever is handed the file.
select is(
  (public.export_my_data() -> 'account') ? 'id',
  false,
  'the exported account block omits the internal id'
);

-- ---------------------------------------------------------------------------
-- 2. Deletion refuses without a deliberate confirmation
-- ---------------------------------------------------------------------------

select throws_ok(
  $$ select public.delete_my_account(null) $$,
  '22023',
  'CONFIRMATION_REQUIRED',
  'deletion with no confirmation is refused'
);

select throws_ok(
  $$ select public.delete_my_account('') $$,
  '22023',
  'CONFIRMATION_REQUIRED',
  'deletion with an empty confirmation is refused'
);

-- Whitespace is trimmed before comparison, so a stray space cannot be used to
-- bypass the literal, and a near-miss phrase is still refused.
select throws_ok(
  $$ select public.delete_my_account('hapus akun saya') $$,
  '22023',
  'CONFIRMATION_REQUIRED',
  'deletion with a near-miss phrase is refused'
);

select is(
  (
    select count(*)::integer
    from public.profiles
    where id = (select user_id from fixture where ordinal = 1)
  ),
  1,
  'the refused attempts left the account in place'
);

-- ---------------------------------------------------------------------------
-- 3. Deletion, and the reports that must survive it
-- ---------------------------------------------------------------------------

-- The server prepares deletion before removing avatar bytes through Storage.
select public.prepare_account_deletion('HAPUS AKUN SAYA');

select lives_ok(
  $$ select public.delete_my_account('HAPUS AKUN SAYA') $$,
  'a confirmed deletion runs'
);

select is(
  (
    select count(*)::integer
    from public.practice_reports
    where title like 'GDPR fixture 1-%'
  ),
  3,
  'the reports survived the account deletion'
);

-- This is the assertion the whole ordering is built around. If the profile had
-- been deleted before the reports were detached, the cascade would have taken
-- these three with it and the previous assertion would read 0.
select is(
  (
    select count(*)::integer
    from public.practice_reports
    where title like 'GDPR fixture 1-%'
      and user_id is null
  ),
  3,
  'every surviving report was detached from its author'
);

select is(
  (
    select count(*)::integer
    from public.practice_reports
    where title like 'GDPR fixture 1-%'
      and author_username = 'Anonim'
  ),
  3,
  'every surviving report shows the author as Anonim'
);

-- Evidence, the URL and the screenshot are the parts that could identify
-- someone else or carry content that was not the author's to keep.
select is(
  (
    select count(*)::integer
    from public.practice_reports
    where title like 'GDPR fixture 1-%'
      and evidence = 'Withdrawn by the author.'
      and why_risky = 'Withdrawn by the author.'
      and defanged_url is null
      and screenshot_path is null
      and screenshot_data_url is null
  ),
  3,
  'evidence, risk text, url and screenshot are gone from the surviving reports'
);

select is(
  (
    select count(*)::integer
    from public.profiles
    where id = (select user_id from fixture where ordinal = 1)
  ),
  0,
  'the profile row is gone'
);

-- Switched to the owner for this one assertion: auth.users is not readable by
-- authenticated, which is correct and is not what is under test here.
reset role;

select is(
  (
    select count(*)::integer
    from auth.users
    where id = (select user_id from fixture where ordinal = 1)
  ),
  0,
  'the authentication record is gone'
);

set local role authenticated;

select is(
  (
    select count(*)::integer
    from public.practice_reports
    where title = 'GDPR fixture 2-Z'
      and user_id = (select user_id from fixture where ordinal = 2)
  ),
  1,
  'the other account''s report is untouched'
);

-- ---------------------------------------------------------------------------
-- 4. The paths are closed afterwards
-- ---------------------------------------------------------------------------

-- A second call cannot succeed: there is no profile, so it stops before the
-- deletes rather than partially re-running them.
select throws_ok(
  $$ select public.delete_my_account('HAPUS AKUN SAYA') $$,
  '22023',
  'PROFILE_NOT_FOUND',
  'deletion cannot be run twice'
);

-- A logged-out visitor cannot reach either path. Verified as the owner because
-- the point is the grant, not the behaviour.
reset role;
set local role postgres;

-- A privilege check, not an existence check. pgTAP's hasnt_function answers
-- "does this function exist", which is false and has nothing to do with who may
-- call it; the functions obviously exist, having just been called.
--
-- Checked as the owner because has_function_privilege needs to name a role.
select is(
  (select has_function_privilege('anon', 'public.export_my_data()', 'execute')),
  false,
  'export is not executable by anon'
);

select is(
  (select has_function_privilege('anon', 'public.delete_my_account(text)', 'execute')),
  false,
  'deletion is not executable by anon'
);

-- And the contrast: authenticated does hold it, or the feature would be
-- unreachable. A revoke that was too broad would not raise, it would simply
-- 403 every user who clicked the button.
select is(
  (select has_function_privilege('authenticated', 'public.export_my_data()', 'execute')),
  true,
  'export is executable by authenticated'
);

select is(
  (select has_function_privilege('authenticated', 'public.delete_my_account(text)', 'execute')),
  true,
  'deletion is executable by authenticated'
);

reset role;

select * from finish();
rollback;
