-- Anonymous Auth users have the `authenticated` Postgres role, so the role
-- alone is not sufficient to grant community report visibility.

begin;

select plan(11);

create temporary table community_fixture (
  anonymous_user_id uuid not null,
  permanent_user_id uuid not null,
  report_id uuid not null
);

insert into community_fixture
values (gen_random_uuid(), gen_random_uuid(), gen_random_uuid());

grant select on community_fixture to authenticated;
grant select on community_fixture to anon;

insert into auth.users (
  instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
  created_at, updated_at, raw_app_meta_data, raw_user_meta_data
)
select
  '00000000-0000-0000-0000-000000000000'::uuid,
  fixture.anonymous_user_id,
  'authenticated',
  'authenticated',
  'community-anonymous-' || fixture.anonymous_user_id::text || '@example.invalid',
  extensions.crypt('test', extensions.gen_salt('bf', 4)),
  now(), now(), now(),
  '{"provider":"anonymous","providers":["anonymous"]}'::jsonb,
  jsonb_build_object('username', 'community_anon_' || left(fixture.anonymous_user_id::text, 8))
from community_fixture as fixture
union all
select
  '00000000-0000-0000-0000-000000000000'::uuid,
  fixture.permanent_user_id,
  'authenticated',
  'authenticated',
  'community-permanent-' || fixture.permanent_user_id::text || '@example.invalid',
  extensions.crypt('test', extensions.gen_salt('bf', 4)),
  now(), now(), now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  jsonb_build_object('username', 'community_user_' || left(fixture.permanent_user_id::text, 8))
from community_fixture as fixture;

insert into public.profiles (id, username, email)
select
  fixture.anonymous_user_id,
  'community_anon_' || left(fixture.anonymous_user_id::text, 8),
  'community-anonymous-' || fixture.anonymous_user_id::text || '@example.invalid'
from community_fixture as fixture
on conflict (id) do nothing;

insert into public.profiles (id, username, email)
select
  fixture.permanent_user_id,
  'community_user_' || left(fixture.permanent_user_id::text, 8),
  'community-permanent-' || fixture.permanent_user_id::text || '@example.invalid'
from community_fixture as fixture
on conflict (id) do nothing;

-- Create one community item and one related record in each read surface.
select set_config(
  'request.jwt.claims',
  jsonb_build_object(
    'sub', (select permanent_user_id::text from community_fixture),
    'role', 'authenticated',
    'is_anonymous', false
  )::text,
  true
);

insert into public.practice_reports (
  id, source, title, category, channel, pattern, evidence, why_risky
)
select
  fixture.report_id,
  'manual',
  'Permanent account visibility fixture',
  'SMS phishing',
  'Text message',
  'Urgency',
  'Synthetic evidence for permanent-user RLS tests.',
  'Synthetic risk explanation for permanent-user RLS tests.'
from community_fixture as fixture;

insert into public.report_signals (report_id, user_id)
select fixture.report_id, fixture.permanent_user_id
from community_fixture as fixture;

insert into public.report_investigation_notes (report_id, user_id, author_role, text)
select fixture.report_id, fixture.permanent_user_id, 'investigator', 'Synthetic investigation note.'
from community_fixture as fixture;

insert into public.report_verdicts (report_id, user_id, author_username, verdict, reason)
select fixture.report_id, fixture.permanent_user_id, 'community_test', 'valid', 'Synthetic verdict reason.'
from community_fixture as fixture;

-- The public profile keeps basic learning information but does not disclose
-- the report and investigation activity created above.
set local role anon;
select ok(
  (public.get_public_profile((
    select 'community_user_' || left(permanent_user_id::text, 8) from community_fixture
  )) ?& array['username', 'modules_completed', 'mastery', 'badges']),
  'anonymous readers receive only the basic public profile fields'
);
select ok(
  not (public.get_public_profile((
    select 'community_user_' || left(permanent_user_id::text, 8) from community_fixture
  )) ?| array['email', 'report_count', 'reports', 'investigations']),
  'anonymous readers cannot see report or investigation activity in a profile'
);
reset role;

-- Anonymous Auth still maps to the authenticated Postgres role, but must see
-- no community rows in any of the four tables.
select set_config(
  'request.jwt.claims',
  jsonb_build_object(
    'sub', (select anonymous_user_id::text from community_fixture),
    'role', 'authenticated',
    'is_anonymous', true
  )::text,
  true
);
set local role authenticated;

select is(
  (select count(*)::integer from public.practice_reports where id = (select report_id from community_fixture)),
  0,
  'anonymous Auth users cannot read community reports'
);
select is(
  (select count(*)::integer from public.report_signals where report_id = (select report_id from community_fixture)),
  0,
  'anonymous Auth users cannot read community signals'
);
select is(
  (select count(*)::integer from public.report_investigation_notes where report_id = (select report_id from community_fixture)),
  0,
  'anonymous Auth users cannot read investigation notes'
);
select is(
  (select count(*)::integer from public.report_verdicts where report_id = (select report_id from community_fixture)),
  0,
  'anonymous Auth users cannot read report verdicts'
);

reset role;

-- Fail closed if an authenticated JWT is missing the anonymity claim.
select set_config(
  'request.jwt.claims',
  jsonb_build_object(
    'sub', (select permanent_user_id::text from community_fixture),
    'role', 'authenticated'
  )::text,
  true
);
set local role authenticated;
select is(
  (select count(*)::integer from public.practice_reports where id = (select report_id from community_fixture)),
  0,
  'missing is_anonymous claim does not grant community access'
);

reset role;

-- A permanent account with an explicit false claim can read the community.
select set_config(
  'request.jwt.claims',
  jsonb_build_object(
    'sub', (select permanent_user_id::text from community_fixture),
    'role', 'authenticated',
    'is_anonymous', false
  )::text,
  true
);
set local role authenticated;

select is(
  (select count(*)::integer from public.practice_reports where id = (select report_id from community_fixture)),
  1,
  'permanent users can read community reports'
);
select is(
  (select count(*)::integer from public.report_signals where report_id = (select report_id from community_fixture)),
  1,
  'permanent users can read community signals'
);
select is(
  (select count(*)::integer from public.report_investigation_notes where report_id = (select report_id from community_fixture)),
  1,
  'permanent users can read investigation notes'
);
select is(
  (select count(*)::integer from public.report_verdicts where report_id = (select report_id from community_fixture)),
  1,
  'permanent users can read report verdicts'
);

select * from finish();
rollback;
