-- Report list ordering.
--
-- A wrong ORDER BY does not raise. It returns rows in the wrong order, which in
-- a paged list means page 2 starts in the middle of a different sequence, so a
-- report can appear twice or never at all. That failure is invisible in review
-- and obvious to a user, so it gets its own test.
--
-- The three orders must match the user-facing report hub: newest (created_at
-- desc, id desc), oldest (created_at asc, id asc), and top (signal_score desc,
-- created_at desc).
--
-- Run with: npx supabase test db

begin;

select plan(13);

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
  'order-test@example.invalid',
  extensions.crypt('order-test-password', extensions.gen_salt('bf', 4)),
  now(), now(), now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  '{"username":"order_test"}'::jsonb
);

insert into public.profiles (id, username, email)
select user_id, 'order_test', 'order-test@example.invalid'
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

create temporary table fixture_admin as
select gen_random_uuid() as admin_id;

insert into public.admin_accounts (id, username, password_hash)
select admin_id, 'order_test_admin', extensions.crypt('order-test-password', extensions.gen_salt('bf', 4))
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

-- Four reports with distinct ages and signal counts. signal_score is a cache
-- maintained by the report_signals trigger, so it is written through signals
-- rather than set directly, which is also what proves that path still works.
--
--   A  oldest, 0 signals
--   B  oldest+1h, 2 signals
--   C  oldest+2h, 0 signals
--   D  oldest+3h, 1 signal
--
-- newest  => D, C, B, A
-- oldest  => A, B, C, D
-- top     => B (2), D (1), then the zero-signal pair newest-first => C, A

insert into public.practice_reports (
  user_id, source, title, category, channel, pattern, evidence, why_risky
)
select
  owner.user_id,
  'manual',
  'Order fixture ' || seed.letter,
  'SMS phishing',
  'Text message',
  'Urgency',
  'Observed evidence for order fixture ' || seed.letter || '.',
  'Urgency applies time pressure to the reader.'
from fixture_user as owner
cross join (values ('A'), ('B'), ('C'), ('D')) as seed(letter);

-- The ages are forced apart here rather than in the INSERT because
-- prepare_practice_report unconditionally runs `new.created_at := now()`, and
-- now() is transaction time: four rows inserted by one statement all get an
-- identical timestamp, which would leave every ordering tie unbroken and let a
-- random uuid id decide. Age ordering therefore has to be written after the
-- fact.
--
-- That update needs the moderation escape hatch. protect_practice_report_system
-- _fields guards created_at against changes, but only for the anon and
-- authenticated roles and only when `alethia.admin_action` is not 'on'. Setting
-- the GUC is how every admin RPC writes these fields, so the fixture uses the
-- same path rather than a test-only bypass.
select set_config('alethia.admin_action', 'on', true);

update public.practice_reports as report
set created_at = now() - (case report.title
  when 'Order fixture A' then interval '4 hours'
  when 'Order fixture B' then interval '3 hours'
  when 'Order fixture C' then interval '2 hours'
  else interval '1 hour'
end)
where report.title like 'Order fixture %';

select set_config('alethia.admin_action', 'off', true);

-- A second account, because report_signals.user_id is a foreign key to
-- profiles(id) and one user can only contribute one signal per report.
insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data
)
values (
  '00000000-0000-0000-0000-000000000000',
  gen_random_uuid(),
  'authenticated',
  'authenticated',
  'order-test-2@example.invalid',
  extensions.crypt('order-test-password', extensions.gen_salt('bf', 4)),
  now(), now(), now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  '{"username":"order_test_2"}'::jsonb
);

insert into public.profiles (id, username, email)
select auth_user.id, 'order_test_2', 'order-test-2@example.invalid'
from auth.users as auth_user
where auth_user.email = 'order-test-2@example.invalid'
on conflict (id) do nothing;

-- signal_score is reset to 0 by prepare_practice_report, so the signal rows
-- are what give B and D their ordering weight. B gets two, D one, A and C
-- none.
insert into public.report_signals (report_id, user_id)
select report.id, owner.user_id
from public.practice_reports as report
cross join fixture_user as owner
where report.title in ('Order fixture B', 'Order fixture D')
on conflict (report_id, user_id) do nothing;

insert into public.report_signals (report_id, user_id)
select report.id, second.id
from public.practice_reports as report
join public.profiles as second
  on second.email = 'order-test-2@example.invalid'
where report.title = 'Order fixture B'
on conflict (report_id, user_id) do nothing;

-- The RPC is revoked from PUBLIC, so this runs as the owner. What is under test
-- is the SQL, not the token gate; 004 covers the gate.
set local role postgres;

-- ---------------------------------------------------------------------------
-- newest / oldest / top
-- ---------------------------------------------------------------------------
--
-- These capture the order the RPC actually returns, via array_agg with no
-- ORDER BY of its own. That is deliberate: adding `order by` inside the
-- aggregate would re-sort the rows and turn every one of these assertions into
-- a test of the row *set*, which would pass no matter what order the RPC chose.
-- A function scan feeds the aggregate in emission order, so what the caller
-- sees is what gets compared.

select is(
  (
    select array_to_string(array_agg(report.title), ',')
    from public.admin_list_reports((select raw_token from fixture_session), null, 'newest') as report
  ),
  'Order fixture D,Order fixture C,Order fixture B,Order fixture A',
  'newest returns the most recent report first'
);

select is(
  (
    select array_to_string(array_agg(report.title), ',')
    from public.admin_list_reports((select raw_token from fixture_session), null, 'oldest') as report
  ),
  'Order fixture A,Order fixture B,Order fixture C,Order fixture D',
  'oldest returns the least recent report first'
);

-- B has 2 signals, D has 1, A and C have none. Ordering by age alone would give
-- D, C, B, A, so this distinguishes a real signal_score ordering from an
-- accidental created_at one, and the trailing A, C pins the tie-break.
select is(
  (
    select array_to_string(array_agg(report.title), ',')
    from public.admin_list_reports((select raw_token from fixture_session), null, 'top') as report
  ),
  'Order fixture B,Order fixture D,Order fixture C,Order fixture A',
  'top ranks by signal_score, breaking ties with the most recent first'
);

-- An unknown or absent sort must fall back to newest rather than raising: it is
-- a display preference, not an input the caller can get wrong meaningfully.
select is(
  (
    select array_to_string(array_agg(report.title), ',')
    from public.admin_list_reports((select raw_token from fixture_session), null, null) as report
  ),
  'Order fixture D,Order fixture C,Order fixture B,Order fixture A',
  'an absent sort falls back to newest'
);

select is(
  (
    select array_to_string(array_agg(report.title), ',')
    from public.admin_list_reports(
      (select raw_token from fixture_session), null, 'not_a_sort'
    ) as report
  ),
  'Order fixture D,Order fixture C,Order fixture B,Order fixture A',
  'an unknown sort falls back to newest'
);

-- ---------------------------------------------------------------------------
-- Paging must not reorder
-- ---------------------------------------------------------------------------

-- The failure this catches: a paged query whose ORDER BY does not match the
-- unpaged one, so page 2 restarts a different sequence. Comparing the paged
-- concatenation against the unpaged list is the direct test.
select is(
  (
    select string_agg(page.title, ',' order by page.ordinal)
    from (
      select report.title, row_number() over () as ordinal
      from public.admin_list_reports(
        (select raw_token from fixture_session), null, 'newest', null, null, null, 2, 0
      ) as report
      union all
      select report.title, row_number() over () + 2 as ordinal
      from public.admin_list_reports(
        (select raw_token from fixture_session), null, 'newest', null, null, null, 2, 2
      ) as report
    ) as page
  ),
  'Order fixture D,Order fixture C,Order fixture B,Order fixture A',
  'paging two rows at a time reproduces the unpaged order'
);

select is(
  (
    select string_agg(page.title, ',' order by page.ordinal)
    from (
      select report.title, row_number() over () as ordinal
      from public.admin_list_reports(
        (select raw_token from fixture_session), null, 'top', null, null, null, 3, 0
      ) as report
      union all
      select report.title, row_number() over () + 3 as ordinal
      from public.admin_list_reports(
        (select raw_token from fixture_session), null, 'top', null, null, null, 3, 3
      ) as report
    ) as page
  ),
  'Order fixture B,Order fixture D,Order fixture C,Order fixture A',
  'paging under the top sort reproduces the unpaged order'
);

-- ---------------------------------------------------------------------------
-- Sort does not disturb the other filters, and count agrees with the list
-- ---------------------------------------------------------------------------

select is(
  (
    select count(*)::integer
    from public.admin_list_reports(
      (select raw_token from fixture_session), 'queued', 'newest'
    ) as report
  ),
  4,
  'a review-status filter of queued still returns every fixture report'
);

select is(
  (
    select public.admin_count_reports(
      (select raw_token from fixture_session), 'queued', null, null, null
    )
  ),
  4,
  'admin_count_reports agrees with admin_list_reports under a status filter'
);

select is(
  (
    select public.admin_count_reports(
      (select raw_token from fixture_session), 'approved', null, null, null
    )
  ),
  0,
  'admin_count_reports returns 0 when nothing matches'
);

-- A search that matches one row must narrow both calls identically.
select is(
  (
    select count(*)::integer
    from public.admin_list_reports(
      (select raw_token from fixture_session), null, 'newest', null, null, 'fixture B'
    ) as report
  ),
  1,
  'search narrows the list to the matching report'
);

select is(
  (
    select public.admin_count_reports(
      (select raw_token from fixture_session), null, null, null, 'fixture B'
    )
  ),
  1,
  'admin_count_reports applies the same search filter'
);

-- An invalid session must raise rather than reading as an empty list, which the
-- list pane cannot distinguish from a real "no results".
select throws_ok(
  $$
    select public.admin_list_reports('not-a-real-token', null, 'newest')
  $$,
  '42501',
  'ADMIN_SESSION_REQUIRED',
  'an invalid session token is rejected rather than returning an empty list'
);

reset role;

select * from finish();
rollback;
