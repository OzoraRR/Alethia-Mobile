-- Author-visible moderation status, and admin deletion.
--
-- 20260926110000 added two things that nothing else covered:
--
--   * reviewer_feedback, the reason the author sees when their report is
--     rejected, written only by a verified admin
--   * admin_delete_reports, which really deletes the report and leaves a
--     tombstone the author can read
--
-- The properties that matter are the ones a reviewer would otherwise have to
-- take on trust: that the author cannot forge or edit their own rejection
-- reason, that a delete takes the derived rows with it, that the tombstone
-- keeps no report content, and that a delete without a reason is refused rather
-- than leaving the author with a notice they cannot act on.
--
-- Run with: npx supabase test db

begin;

select plan(25);

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------

create temporary table fixture_users as
select ordinal, gen_random_uuid() as user_id
from generate_series(1, 2) as ordinal;

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data
)
select
  '00000000-0000-0000-0000-000000000000',
  user_id,
  'authenticated',
  'authenticated',
  'deletion-test-' || ordinal || '@example.invalid',
  extensions.crypt('deletion-test-password', extensions.gen_salt('bf', 4)),
  now(), now(), now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  jsonb_build_object('username', 'deletion_test_' || ordinal)
from fixture_users;

insert into public.profiles (id, username, email)
select user_id, 'deletion_test_' || ordinal, 'deletion-test-' || ordinal || '@example.invalid'
from fixture_users
on conflict (id) do nothing;

-- Set before the report insert: prepare_practice_report raises
-- AUTHENTICATION_REQUIRED without a caller, and the fixtures below are authored
-- by user 1.
select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', (select user_id::text from fixture_users where ordinal = 1),
    'role', 'authenticated',
    'is_anonymous', false
  )::text,
  true
);

create temporary table fixture_admin as
select gen_random_uuid() as admin_id;

insert into public.admin_accounts (id, username, password_hash)
select
  admin_id,
  'deletion_test_admin',
  extensions.crypt('deletion-test-password', extensions.gen_salt('bf', 4))
from fixture_admin;

create temporary table fixture_session as
select
  encode(extensions.gen_random_bytes(32), 'hex') as raw_token,
  gen_random_uuid() as session_id,
  (select admin_id from fixture_admin) as admin_id;

insert into public.admin_sessions (id, admin_id, token_hash, expires_at)
select session_id, admin_id, encode(extensions.digest(raw_token, 'sha256'), 'hex'), now() + interval '1 hour'
from fixture_session;

-- Three reports owned by user 1. Each needs a distinct title because the
-- helpers below address them by title.
insert into public.practice_reports (
  user_id, source, title, category, channel, pattern, evidence, why_risky, defanged_url
)
select
  owner.user_id,
  'manual',
  'Deletion fixture ' || suffix,
  'SMS phishing',
  'Text message',
  'Urgency',
  'Observed evidence for deletion fixture ' || suffix || '.',
  'Urgency applies time pressure to the reader.',
  'hxxps://example[.]invalid/' || suffix
from fixture_users as owner
cross join (values ('A'), ('B'), ('C')) as seed(suffix)
where owner.ordinal = 1;

-- Signals, an investigation note and a review event on report A, so the delete
-- has derived rows to cascade and the test can prove they went.
insert into public.report_signals (report_id, user_id)
select report.id, owner.user_id
from public.practice_reports as report, fixture_users as owner
where report.title = 'Deletion fixture A' and owner.ordinal = 1;

insert into public.report_investigation_notes (report_id, user_id, author_role, text)
select report.id, owner.user_id, 'investigator', 'Investigator note on the deletion fixture.'
from public.practice_reports as report, fixture_users as owner
where report.title = 'Deletion fixture A' and owner.ordinal = 1;

-- The RPCs are revoked from PUBLIC, so these run as the owner. What is under
-- test is the body, not the token gate, which the last assertion covers.
set local role postgres;

-- ---------------------------------------------------------------------------
-- 1. reviewer_feedback
-- ---------------------------------------------------------------------------

select is(
  public.apply_report_review(
    (select raw_token from fixture_session),
    array[(select id from public.practice_reports where title = 'Deletion fixture A')],
    'Triaged',
    'rejected',
    'Internal triage note.',
    'Defanged URLs cannot be verified from the field, so resubmit with the domain broken out.'
  ),
  1,
  'an admin can reject a report with feedback for the author'
);

select is(
  (
    select report.reviewer_feedback
    from public.practice_reports as report
    where report.title = 'Deletion fixture A'
  ),
  'Defanged URLs cannot be verified from the field, so resubmit with the domain broken out.',
  'the rejection reason is stored on the report'
);

select is(
  (
    select report.admin_note
    from public.practice_reports as report
    where report.title = 'Deletion fixture A'
  ),
  'Internal triage note.',
  'the moderation-internal note is stored separately from the author-facing feedback'
);

-- Approving later must clear it, or the author sees "rejected because X" on a
-- report that was accepted.
select is(
  public.apply_report_review(
    (select raw_token from fixture_session),
    array[(select id from public.practice_reports where title = 'Deletion fixture A')],
    'Learning note',
    'approved',
    'Accepted.',
    'stale reason that must not survive approval'
  ),
  1,
  'the same report can be approved afterwards'
);

select is(
  (
    select report.reviewer_feedback
    from public.practice_reports as report
    where report.title = 'Deletion fixture A'
  ),
  null,
  'approving clears the rejection reason'
);

-- The author cannot write their own rejection reason. Without reviewer_feedback
-- in the guard list this column would be an ordinary updatable field and an
-- author could set "approved by the team" on their own report.
reset role;
select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', (select user_id::text from fixture_users where ordinal = 1),
    'role', 'authenticated',
    'is_anonymous', false
  )::text,
  true
);
set local role authenticated;

select throws_ok(
  $$
    update public.practice_reports
    set reviewer_feedback = 'Please treat this as approved.'
    where title = 'Deletion fixture A'
  $$,
  '42501',
  'PRACTICE_REPORT_SYSTEM_FIELDS_IMMUTABLE',
  'an author cannot set their own rejection reason'
);

-- ---------------------------------------------------------------------------
-- 2. Rejecting without a reason is refused
-- ---------------------------------------------------------------------------

reset role;
set local role postgres;

select throws_ok(
  $$
    select public.apply_report_review(
      (select raw_token from fixture_session),
      array[(select id from public.practice_reports where title = 'Deletion fixture B')],
      'Triaged',
      'rejected',
      'Internal note.',
      null
    )
  $$,
  '22023',
  'REVIEW_FEEDBACK_REQUIRED',
  'a rejection with no reason for the author is refused'
);

select is(
  (
    select report.review_status
    from public.practice_reports as report
    where report.title = 'Deletion fixture B'
  ),
  'queued',
  'the refused rejection left the report queued'
);

-- ---------------------------------------------------------------------------
-- 3. Feedback reaches the single and bulk review paths
-- ---------------------------------------------------------------------------

-- The admin console calls one wrapper per shape, not apply_report_review
-- directly. If the wrappers are not threaded, the author simply never sees a
-- reason and nothing errors.
select is(
  public.admin_update_report(
    (select raw_token from fixture_session),
    (select id from public.practice_reports where title = 'Deletion fixture B'),
    'Triaged',
    'rejected',
    'Internal note.',
    'The screenshot is missing; attach one so the pattern can be confirmed.'
  ),
  true,
  'the single-report wrapper accepts feedback'
);

select is(
  (
    select report.reviewer_feedback
    from public.practice_reports as report
    where report.title = 'Deletion fixture B'
  ),
  'The screenshot is missing; attach one so the pattern can be confirmed.',
  'the single-report wrapper stored the author-facing feedback'
);

select is(
  public.admin_bulk_update_reports(
    (select raw_token from fixture_session),
    array[(select id from public.practice_reports where title = 'Deletion fixture C')],
    'Triaged',
    'rejected',
    'Internal note.',
    'The defanged domain cannot be resolved from the description alone.'
  ),
  1,
  'the bulk wrapper accepts feedback'
);

select is(
  (
    select report.reviewer_feedback
    from public.practice_reports as report
    where report.title = 'Deletion fixture C'
  ),
  'The defanged domain cannot be resolved from the description alone.',
  'the bulk wrapper stored the author-facing feedback'
);

-- ---------------------------------------------------------------------------
-- 4. admin_delete_reports
-- ---------------------------------------------------------------------------

-- The id is captured before the delete so the cascade assertion can name it.
-- Asserting "no orphans remain" alone would pass even if the delete had never
-- happened, which is exactly what happened the first time this test ran.
create temporary table fixture_target as
select id from public.practice_reports where title = 'Deletion fixture A';

-- 1 signal + 1 investigation note + 2 review events (the reject above and the
-- approval after it).
select is(
  (
    select
      (select count(*) from public.report_signals where report_id = (select id from fixture_target))
      + (select count(*) from public.report_investigation_notes where report_id = (select id from fixture_target))
      + (select count(*) from public.report_review_events where report_id = (select id from fixture_target))
  ),
  4::bigint,
  'the report has derived rows before the delete, so the cascade assertion below means something'
);

select lives_ok(
  $$
    select public.admin_delete_reports(
      (select raw_token from fixture_session),
      array[(select id from fixture_target)],
      'Duplicate of an existing report; resubmit once.'
    )
  $$,
  'an admin can delete a report'
);

select is(
  (
    select count(*)::integer
    from public.practice_reports
    where id = (select id from fixture_target)
  ),
  0,
  'the report row is gone'
);

select is(
  (
    select
      (select count(*) from public.report_signals where report_id = (select id from fixture_target))
      + (select count(*) from public.report_investigation_notes where report_id = (select id from fixture_target))
      + (select count(*) from public.report_review_events where report_id = (select id from fixture_target))
  ),
  0::bigint,
  'signals, investigation notes and review events all cascaded with the report'
);

-- Read the tombstone by reason and title, since the report row it refers to is
-- gone and can no longer be joined back to.
select is(
  (
    select count(*)::integer
    from public.report_deletions as deletion
    where deletion.reason = 'Duplicate of an existing report; resubmit once.'
      and deletion.author_title = 'Deletion fixture A'
      and deletion.deleted_by = 'deletion_test_admin'
  ),
  1,
  'a tombstone names the report, the reason and the admin who removed it'
);

-- The point of a real delete. If any of these survived, "deleted" would be a
-- claim rather than a fact.
select is(
  (
    select count(*)::integer
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'report_deletions'
      and column_name in ('evidence', 'defanged_url', 'screenshot_data_url', 'channel', 'pattern', 'why_risky', 'signal_score')
  ),
  0,
  'the tombstone table has no column capable of holding report content'
);

-- ---------------------------------------------------------------------------
-- 4. Tombstone visibility is owner-only
-- ---------------------------------------------------------------------------

reset role;
select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', (select user_id::text from fixture_users where ordinal = 1),
    'role', 'authenticated',
    'is_anonymous', false
  )::text,
  true
);
set local role authenticated;

select is(
  (
    select count(*)::integer
    from public.report_deletions
  ),
  1,
  'the author can read the notice about their own deleted report'
);

reset role;
select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', (select user_id::text from fixture_users where ordinal = 2),
    'role', 'authenticated',
    'is_anonymous', false
  )::text,
  true
);
set local role authenticated;

select is(
  (
    select count(*)::integer
    from public.report_deletions
  ),
  0,
  'another user cannot read that notice'
);

-- There is no insert, update or delete policy, so the author cannot forge or
-- erase a notice. The grant is select only, so this fails on privilege rather
-- than on policy.
select throws_ok(
  $$
    insert into public.report_deletions (report_id, owner_id, author_title, reason, deleted_by)
    values (gen_random_uuid(), auth.uid(), 'Forged', 'Forged notice.', 'forged')
  $$,
  '42501',
  null,
  'a client cannot write a tombstone'
);

-- ---------------------------------------------------------------------------
-- 5. Delete guards
-- ---------------------------------------------------------------------------

reset role;
set local role postgres;

select throws_ok(
  $$
    select public.admin_delete_reports(
      (select raw_token from fixture_session),
      array[(select id from public.practice_reports where title = 'Deletion fixture C')],
      'no'
    )
  $$,
  '22023',
  'DELETION_REASON_REQUIRED',
  'a delete with no reason is refused'
);

select is(
  (
    select count(*)::integer
    from public.practice_reports
    where title = 'Deletion fixture C'
  ),
  1,
  'the refused delete left the report in place'
);

-- A stale id from the admin pane must not read as a successful delete.
select throws_ok(
  $$
    select public.admin_delete_reports(
      (select raw_token from fixture_session),
      array[gen_random_uuid()],
      'Removing a report that does not exist.'
    )
  $$,
  '22023',
  'REPORT_NOT_FOUND',
  'deleting an unknown id is reported rather than silently succeeding'
);

select throws_ok(
  $$
    select public.admin_delete_reports(
      'not-a-real-token',
      array[gen_random_uuid()],
      'Removing a report with a bad token.'
    )
  $$,
  '42501',
  'ADMIN_SESSION_REQUIRED',
  'an invalid session token cannot delete a report'
);

reset role;

select * from finish();
rollback;
