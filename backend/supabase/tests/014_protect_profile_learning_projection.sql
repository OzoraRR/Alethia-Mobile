begin;
select plan(13);

create temporary table fixture_user as select gen_random_uuid() as user_id;
insert into auth.users (
  instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,
  raw_app_meta_data,raw_user_meta_data
)
select
  '00000000-0000-0000-0000-000000000000',user_id,'authenticated','authenticated',
  'learning-projection@example.invalid',extensions.crypt('test',extensions.gen_salt('bf',4)),now(),now(),now(),
  '{"provider":"email","providers":["email"]}'::jsonb,'{"username":"learning_projection"}'::jsonb
from fixture_user;

create temporary table report_fixture (report_id uuid);
create temporary table sms_attempt (attempt_id uuid);
create temporary table social_attempt (attempt_id uuid);
grant select, insert on fixture_user, report_fixture, sms_attempt, social_attempt to authenticated;

select set_config(
  'request.jwt.claims',
  json_build_object('sub',(select user_id::text from fixture_user),'role','authenticated','is_anonymous',false)::text,
  true
);

with inserted as (
  insert into public.practice_reports (
    source,title,category,channel,pattern,evidence,why_risky
  ) values (
    'manual','Projection guard test','SMS phishing','Text message','Urgency',
    'Synthetic evidence for the projection-guard SQL test.',
    'The time pressure discourages independent verification.'
  ) returning id
)
insert into report_fixture select id from inserted;

set local role authenticated;

select throws_ok(
  $$update public.profiles set modules_completed=2 where id=(select user_id from fixture_user)$$,
  '42501','PROFILE_LEARNING_PROJECTION_IMMUTABLE',
  'authenticated users cannot set their own completed-module projection'
);
select throws_ok(
  $$update public.profiles set mastery='skilled' where id=(select user_id from fixture_user)$$,
  '42501','PROFILE_LEARNING_PROJECTION_IMMUTABLE',
  'authenticated users cannot set their own mastery projection'
);
select throws_ok(
  $$insert into public.profiles(id,username,email,modules_completed,mastery)
    select user_id,'learning_projection','learning-projection@example.invalid',2,'skilled' from fixture_user
    on conflict (id) do nothing$$,
  '42501','PROFILE_LEARNING_PROJECTION_IMMUTABLE',
  'authenticated profile inserts cannot seed forged learning projections'
);
select throws_ok(
  $$select public.cast_report_verdict((select report_id from report_fixture),'valid','Synthetic review')$$,
  '42501','INVESTIGATOR_REQUIRED',
  'the verdict RPC requires two completed module progress rows'
);

reset role;
-- Simulate a stale/tampered projection from before this forward migration.
update public.profiles set modules_completed=2 where id=(select user_id from fixture_user);
set local role authenticated;

select is(
  (select modules_completed from public.profiles where id=(select user_id from fixture_user)),
  2,
  'the test fixture contains a stale forged count before authority checks'
);
select is(
  (select access_state = 'locked' from public.get_module_access() where module_id = 'social-engineering'),
  true,
  'a stale profile count does not unlock Social Engineering through the allowed RPC'
);
select throws_ok(
  $$select public.begin_verified_practice_attempt('social-engineering')$$,
  '42501','MODULE_LOCKED',
  'the attempt RPC refuses Social Engineering despite a forged profile count'
);
select throws_ok(
  $$select public.cast_report_verdict((select report_id from report_fixture),'valid','Synthetic review')$$,
  '42501','INVESTIGATOR_REQUIRED',
  'the verdict RPC ignores a forged profile count and checks authoritative progress'
);

insert into sms_attempt
select public.begin_verified_practice_attempt('courier-sms');
select is(
  (select score::integer from public.complete_verified_practice_attempt(
    (select attempt_id from sms_attempt),
    '["assess:sender_unverified","assess:link_suspicious","verify_official_channel","choose:verify_official_channel"]'::jsonb
  )),
  100,
  'a verified perfect SMS attempt completes through the existing server RPC'
);
insert into social_attempt
select public.begin_verified_practice_attempt('social-engineering');
select is(
  (select score from public.complete_verified_practice_attempt(
    (select attempt_id from social_attempt),
    '["artifact:visual","artifact:routine","mitigation:limit","complete:reconstruction"]'::jsonb
  )),
  null::smallint,
  'Social Engineering remains an unscored completion'
);
select is(
  (select modules_completed from public.profiles where id=(select user_id from fixture_user)),
  2,
  'trusted progress triggers restore the completed-module projection from source rows'
);
select is(
  (select mastery from public.profiles where id=(select user_id from fixture_user)),
  'skilled',
  'trusted progress triggers derive mastery from completed module rows'
);
select is(
  (public.cast_report_verdict((select report_id from report_fixture),'valid','Synthetic review')->>'valid'),
  '1',
  'the verdict RPC succeeds after two authoritative module completions'
);

select * from finish();
rollback;
