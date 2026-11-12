-- Cursor pagination and optimistic locking.
--
-- Both features exist to stop data being lost quietly, which is why they get
-- tests that reconstruct the original failure rather than checking the happy
-- path.
--
-- The pagination failure, concretely: reports newest-first are D, C, B, A. Page
-- one takes D and C. A new report E arrives. Offset pagination asks for offset
-- two and gets C and B -- C is on the page twice and A is never shown. Nothing
-- errors. The operator has simply never seen report A.
--
-- The locking failure: two moderators open the same report, both type a note,
-- and the second write silently replaces the first.
--
-- Protocol under test: the function returns requested_limit + 1 rows. The caller
-- displays the first requested_limit and treats the extra row as the cursor.
-- Fewer rows than that means the results are exhausted.
--
-- Run with: npx supabase test db

begin;

select plan(25);

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
  'cursor-test@example.invalid',
  extensions.crypt('cursor-test-password', extensions.gen_salt('bf', 4)),
  now(), now(), now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  '{"username":"cursor_test"}'::jsonb
);

insert into public.profiles (id, username, email)
select user_id, 'cursor_test', 'cursor-test@example.invalid'
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
select admin_id, 'cursor_test_admin', extensions.crypt('cursor-test-password', extensions.gen_salt('bf', 4))
from fixture_admin;

create temporary table fixture_session as
select
  encode(extensions.gen_random_bytes(32), 'hex') as raw_token,
  gen_random_uuid() as session_id,
  (select admin_id from fixture_admin) as admin_id;

insert into public.admin_sessions (id, admin_id, token_hash, expires_at)
select session_id, admin_id, encode(extensions.digest(raw_token, 'sha256'), 'hex'), now() + interval '1 hour'
from fixture_session;

-- Four reports, oldest to newest: A, B, C, D. Ages are written after the insert
-- because prepare_practice_report forces created_at to the transaction time,
-- which would make all four identical and leave every ordering tie unbroken.
insert into public.practice_reports (
  user_id, source, title, category, channel, pattern, evidence, why_risky
)
select
  owner.user_id,
  'manual',
  'Cursor fixture ' || seed.letter,
  'SMS phishing',
  'Text message',
  'Urgency',
  'Observed evidence for cursor fixture ' || seed.letter || '.',
  'Urgency applies time pressure to the reader.'
from fixture_user as owner
cross join (values ('A'), ('B'), ('C'), ('D')) as seed(letter);

select set_config('alethia.admin_action', 'on', true);

update public.practice_reports as report
set created_at = now() - (case report.title
  when 'Cursor fixture A' then interval '4 hours'
  when 'Cursor fixture B' then interval '3 hours'
  when 'Cursor fixture C' then interval '2 hours'
  else interval '1 hour'
end)
where report.title like 'Cursor fixture %';

select set_config('alethia.admin_action', 'off', true);

set local role postgres;

-- ---------------------------------------------------------------------------
-- 1. A row arriving mid-scroll must not shift the page
-- ---------------------------------------------------------------------------

-- Row positions are numbered outside the function call, because the function
-- returns rows in order and this is the only place the position is known.
create temporary table page1 as
select
  page.title,
  page.created_at,
  page.id,
  page.signal_score,
  row_number() over () as pos
from public.admin_list_reports_cursor(
  (select raw_token from fixture_session), null, 'newest', null, null, null, 2
) as page;

select is(
  (select count(*)::integer from page1),
  3,
  'a page returns one row more than the limit, for use as the cursor'
);

select is(
  (select string_agg(title, ',' order by pos) from page1 where pos <= 2),
  'Cursor fixture D,Cursor fixture C',
  'the first page displays the two newest reports'
);

select is(
  (select title from page1 where pos = 2),
  'Cursor fixture C',
  'the cursor is the last row displayed, not the extra row'
);

-- The moderator starts approving reports, so new ones start arriving.
insert into public.practice_reports (
  user_id, source, title, category, channel, pattern, evidence, why_risky
)
select
  owner.user_id, 'manual', 'Cursor fixture E', 'SMS phishing', 'Text message',
  'Urgency', 'Arrived while the operator was paging.', 'Time pressure.'
from fixture_user as owner;

-- With offset pagination this page is "offset 2" over a now five-row list, which
-- is C and B: C appears on two consecutive pages and A is never reached. With a
-- cursor the comparison is against the last row actually displayed, so the
-- newly arrived E is not in this result, C is not repeated, and A is reached.
create temporary table page2 as
select page.title, page.created_at, page.id, page.signal_score, row_number() over () as pos
from public.admin_list_reports_cursor(
  (select raw_token from fixture_session), null, 'newest', null, null, null, 2,
  (select created_at from page1 where pos = 2),
  (select id from page1 where pos = 2)
) as page;

select is(
  (select string_agg(title, ',' order by pos) from page2 where pos <= 2),
  'Cursor fixture B,Cursor fixture A',
  'a report arriving mid-scroll does not repeat or skip anything'
);

-- E arrived after the operator had already scrolled past the top of the list, so
-- it is not in what they walked. It is not a loss: the next refresh starts from
-- the top again. The guarantee is that nothing already seen is repeated and
-- nothing already there is skipped.
select is(
  (
    select count(*)::integer
    from (select title from page1 where pos <= 2
          union all
          select title from page2 where pos <= 2) as seen
    where seen.title = 'Cursor fixture E'
  ),
  0,
  'a report that arrived after the walk started is not mixed into it'
);

-- ---------------------------------------------------------------------------
-- 2. Walking the pages covers everything exactly once
-- ---------------------------------------------------------------------------
--
-- Two pages, written out rather than as a recursive CTE, because each page''s
-- cursor comes from the previous page''s last displayed row.

-- Everything the walk displayed, across both pages.
create temporary table walked as
select title, created_at, id from page1 where pos <= 2
union all
select title, created_at, id from page2 where pos <= 2;

select is(
  (select count(*)::integer from walked),
  4,
  'walking the pages returns every report'
);

select is(
  (select count(distinct title)::integer from walked),
  4,
  'no report appears on two pages'
);

select is(
  (select string_agg(title, ',' order by created_at desc, id desc) from walked),
  'Cursor fixture D,Cursor fixture C,Cursor fixture B,Cursor fixture A',
  'the walk reproduces the unpaged order'
);

-- The same walk under the top sort, whose cursor key is a three-part tuple
-- rather than (created_at, id). A cursor fix that only handled the two-part key
-- would repeat or skip rows here.
create temporary table top1 as
select page.title, page.signal_score, page.created_at, page.id, row_number() over () as pos
from public.admin_list_reports_cursor(
  (select raw_token from fixture_session), null, 'top', null, null, null, 2
) as page;

create temporary table top2 as
select page.title, page.signal_score, page.created_at, page.id, row_number() over () as pos
from public.admin_list_reports_cursor(
  (select raw_token from fixture_session), null, 'top', null, null, null, 2,
  (select created_at from top1 where pos = 2),
  (select id from top1 where pos = 2),
  (select signal_score from top1 where pos = 2)
) as page;

create temporary table walked_top as
select title from top1 where pos <= 2
union all
select title from top2 where pos <= 2;

select is(
  (select count(distinct title)::integer from walked_top),
  4,
  'the top-sort walk also returns each report exactly once'
);

-- ---------------------------------------------------------------------------
-- 3. The end of the list is distinguishable from an empty page
-- ---------------------------------------------------------------------------

-- A short page is the only end-of-list signal, so it has to actually happen.
select is(
  (
    select count(*)::integer
    from public.admin_list_reports_cursor(
      (select raw_token from fixture_session), null, 'newest', null, null, null, 50
    ) as page
  ),
  5,
  'asking for more than exist returns every row and no more'
);

select is(
  (
    select count(*)::integer
    from public.admin_list_reports_cursor(
      (select raw_token from fixture_session), null, 'newest', null, null, null, 2,
      (select created_at from page1 where pos = 2),
      (select id from page1 where pos = 2)
    ) as page
  ),
  2,
  'the final page is short, which is how the caller knows to stop'
);

-- An invalid token must be rejected, not read as an empty queue.
select throws_ok(
  $$
    select public.admin_list_reports_cursor('not-a-real-token', null, 'newest')
  $$,
  '42501',
  'ADMIN_SESSION_REQUIRED',
  'an invalid session token cannot read the queue'
);

-- ---------------------------------------------------------------------------
-- 4. Optimistic locking
-- ---------------------------------------------------------------------------

create temporary table lock_target as
select id, review_version from public.practice_reports where title = 'Cursor fixture D';

select is(
  (select review_version from lock_target),
  0,
  'a report starts at version 0'
);

select is(
  public.apply_report_review(
    (select raw_token from fixture_session),
    array[(select id from lock_target)],
    'Triaged', 'approved', 'First reviewer note.', null, 0
  ),
  1,
  'a review that states the version it read is accepted'
);

select is(
  (select review_version from public.practice_reports where title = 'Cursor fixture D'),
  1,
  'the accepted review incremented the version'
);

-- The second moderator still has version 0 open. Without the check their note
-- would replace the first one and the first would leave no trace.
select throws_ok(
  $$
    select public.apply_report_review(
      (select raw_token from fixture_session),
      array[(select id from lock_target)],
      'Triaged', 'rejected', 'Second reviewer note.', 'Stale edit.', 0
    )
  $$,
  '40001',
  'REPORT_VERSION_CONFLICT: ' || (select id::text from lock_target),
  'a review based on a stale version is refused'
);

select is(
  (select report.admin_note from public.practice_reports as report where report.title = 'Cursor fixture D'),
  'First reviewer note.',
  'the refused review did not overwrite the first reviewer''s note'
);

select is(
  (select report.review_status from public.practice_reports as report where report.title = 'Cursor fixture D'),
  'approved',
  'the refused review did not change the status either'
);

-- Re-reading the version and retrying is the intended path.
select is(
  public.apply_report_review(
    (select raw_token from fixture_session),
    array[(select id from lock_target)],
    'Learning note', 'approved', 'Second reviewer, now current.', null, 1
  ),
  1,
  're-reading the version and retrying succeeds'
);

-- ---------------------------------------------------------------------------
-- 5. Bulk and client behaviour
-- ---------------------------------------------------------------------------

-- Bulk ignores versions on purpose: an operator who selected forty rows and
-- chose approve means it. But the version still moves, so a later single edit
-- on any of those rows notices.
create temporary table bulk_target as
select
  (select id from public.practice_reports where title = 'Cursor fixture A') as a_id,
  (select id from public.practice_reports where title = 'Cursor fixture B') as b_id;

select is(
  public.admin_bulk_update_reports(
    (select raw_token from fixture_session),
    array[(select a_id from bulk_target), (select b_id from bulk_target)],
    'Triaged', 'approved', 'Bulk decision.', null
  ),
  2,
  'a bulk review applies without being blocked by a version check'
);

select is(
  (
    select count(*)::integer
    from public.practice_reports
    where title in ('Cursor fixture A', 'Cursor fixture B')
      and review_version = 1
  ),
  2,
  'bulk review still increments the version on every row it touched'
);

-- The version is a moderation field, so a client cannot bump it to invalidate
-- every operator currently holding the report open.
reset role;
select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', (select user_id::text from fixture_user),
    'role', 'authenticated',
    'is_anonymous', false
  )::text,
  true
);
set local role authenticated;

select throws_ok(
  $$
    update public.practice_reports
    set review_version = 99
    where title = 'Cursor fixture A'
  $$,
  '42501',
  'PRACTICE_REPORT_SYSTEM_FIELDS_IMMUTABLE',
  'a client cannot bump review_version'
);

reset role;
set local role postgres;

-- ---------------------------------------------------------------------------
-- 6. Detail state carries both fields the pane needs
-- ---------------------------------------------------------------------------

select is(
  public.admin_get_report_state(
    (select raw_token from fixture_session),
    (select id from lock_target)
  ) ->> 'review_status',
  'approved',
  'admin_get_report_state reports the current review status'
);

-- 2, not 1: the retry above was the second accepted write against this report.
select is(
  (
    public.admin_get_report_state(
      (select raw_token from fixture_session),
      (select id from lock_target)
    ) ->> 'review_version'
  )::integer,
  2,
  'admin_get_report_state reports the current version'
);

select throws_ok(
  $$
    select public.admin_get_report_state(
      (select raw_token from fixture_session), gen_random_uuid()
    )
  $$,
  '22023',
  'REPORT_NOT_FOUND',
  'admin_get_report_state names an unknown report rather than returning empty state'
);

reset role;

select * from finish();
rollback;
