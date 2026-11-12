begin;
select plan(34);

create temporary table fixture_user as select gen_random_uuid() as user_id;
insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,raw_app_meta_data,raw_user_meta_data)
select '00000000-0000-0000-0000-000000000000', user_id, 'authenticated', 'authenticated',
  'server-score-test@example.invalid', extensions.crypt('test', extensions.gen_salt('bf',4)), now(), now(), now(),
  '{"provider":"email","providers":["email"]}'::jsonb, '{"username":"server_score_test"}'::jsonb
from fixture_user;
insert into public.profiles (id,username,email)
select user_id,'server_score_test','server-score-test@example.invalid' from fixture_user
on conflict (id) do nothing;

create temporary table other_user as select gen_random_uuid() as user_id;
insert into auth.users (instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,raw_app_meta_data,raw_user_meta_data)
select '00000000-0000-0000-0000-000000000000', user_id, 'authenticated', 'authenticated',
  'server-score-other@example.invalid', extensions.crypt('test', extensions.gen_salt('bf',4)), now(), now(), now(),
  '{"provider":"email","providers":["email"]}'::jsonb, '{"username":"server_score_other"}'::jsonb
from other_user;
insert into public.profiles (id,username,email)
select user_id,'server_score_other','server-score-other@example.invalid' from other_user
on conflict (id) do nothing;

select set_config('request.jwt.claims', json_build_object('sub',(select user_id::text from fixture_user),'role','authenticated','is_anonymous',false)::text,true);
select is(public.is_module_unlocked('social-engineering'), false, 'Social Engineering is locked before a verified SMS result');
select is(has_function_privilege('anon', 'public.module_access_state(uuid, smallint, text)', 'execute'), false,
  'anonymous clients cannot query another user through the definer helper');
select is(has_function_privilege('authenticated', 'public.module_access_state(uuid, smallint, text)', 'execute'), false,
  'authenticated clients cannot query another user through the definer helper');
select is(has_function_privilege('service_role', 'public.module_access_state(uuid, smallint, text)', 'execute'), false,
  'the service role cannot invoke the caller-selected definer helper');
select throws_ok($$select public.begin_verified_practice_attempt('social-engineering')$$, '42501', 'MODULE_LOCKED', 'the attempt RPC refuses a locked module');

create temporary table sms_attempt as select public.begin_verified_practice_attempt('courier-sms') as id;
select set_config('request.jwt.claims', json_build_object('sub',(select user_id::text from other_user),'role','authenticated','is_anonymous',false)::text,true);
select throws_ok($$select public.complete_verified_practice_attempt((select id from sms_attempt),
  '["assess:sender_unverified","assess:link_suspicious","verify_official_channel","choose:verify_official_channel"]'::jsonb)$$,
  '42501', 'ATTEMPT_NOT_FOUND', 'foreign attempt ownership is enforced');
select set_config('request.jwt.claims', json_build_object('sub',(select user_id::text from fixture_user),'role','authenticated','is_anonymous',false)::text,true);
select is((select score::integer from public.complete_verified_practice_attempt((select id from sms_attempt),
  '["assess:sender_unverified","assess:link_suspicious","verify_official_channel","choose:verify_official_channel"]'::jsonb)), 100,
  'the server computes a perfect SMS result from meaningful assessments');
select is(public.is_module_unlocked('social-engineering'), true, 'a verified perfect SMS result unlocks Social Engineering');

create temporary table social_attempt as select public.begin_verified_practice_attempt('social-engineering') as id;
create temporary table social_result as select * from public.complete_verified_practice_attempt((select id from social_attempt),
  '["artifact:visual","artifact:routine","mitigation:limit","complete:reconstruction"]'::jsonb);
select is((select score from social_result), null::smallint,
  'Social Engineering completion has no score');
select is((select perfect from social_result), null::boolean, 'Social Engineering does not return a perfect flag');
select is((select outcome from public.practice_attempts where id=(select id from social_attempt)), 'completed',
  'the unscored reconstruction is recorded as completed, not scored safe or unsafe');
select is((select completed_at is not null from public.practice_attempts where id=(select id from social_attempt)), true,
  'the unscored attempt stores its completion time');
select is((select status from public.user_module_progress where user_id=(select user_id from fixture_user) and module_id='social-engineering'), 'completed',
  'the server stores Social Engineering completion');
select is((select score from public.user_module_progress where user_id=(select user_id from fixture_user) and module_id='social-engineering'), null::smallint,
  'the unscored completion does not invent a progress score');
select is(public.is_module_unlocked('executable-file'), true,
  'any completed Social Engineering reconstruction unlocks Malicious Document after perfect SMS');

create temporary table social_all_artifacts as select public.begin_verified_practice_attempt('social-engineering') as id;
select is((select score from public.complete_verified_practice_attempt((select id from social_all_artifacts),
  '["artifact:visual","artifact:routine","artifact:complaint","artifact:career","artifact:family","mitigation:verify","complete:reconstruction"]'::jsonb)),
  null::smallint, 'all five artifacts are accepted in extraction order without introducing a score');

create temporary table social_one_artifact as select public.begin_verified_practice_attempt('social-engineering') as id;
select throws_ok($$select public.complete_verified_practice_attempt((select id from social_one_artifact),
  '["artifact:visual","mitigation:limit","complete:reconstruction"]'::jsonb)$$,
  '22023', 'INVALID_DECISION_SEQUENCE', 'the server rejects fewer than two selected artifacts');
create temporary table social_bad_order as select public.begin_verified_practice_attempt('social-engineering') as id;
select throws_ok($$select public.complete_verified_practice_attempt((select id from social_bad_order),
  '["mitigation:limit","artifact:visual","artifact:family","complete:reconstruction"]'::jsonb)$$,
  '22023', 'INVALID_DECISION_SEQUENCE', 'the server rejects artifacts sent after mitigation');
create temporary table social_unknown_artifact as select public.begin_verified_practice_attempt('social-engineering') as id;
select throws_ok($$select public.complete_verified_practice_attempt((select id from social_unknown_artifact),
  '["artifact:visual","artifact:routine","artifact:other","mitigation:limit","complete:reconstruction"]'::jsonb)$$,
  '22023', 'INVALID_DECISION_SEQUENCE', 'the server accepts only the five allow-listed artifact decisions');

create temporary table social_retry as select public.begin_verified_practice_attempt('social-engineering') as id;
select is((select outcome from public.practice_attempts where id=(select id from social_retry)) is null, true,
  'a new Social retry remains pending until its final decision sequence is submitted');
select is((select score from public.complete_verified_practice_attempt((select id from social_retry),
  '["artifact:complaint","artifact:family","mitigation:separate","complete:reconstruction"]'::jsonb)), null::smallint,
  'a different non-scored mitigation also completes without a score');
select is((select status from public.user_module_progress where user_id=(select user_id from fixture_user) and module_id='social-engineering'), 'completed',
  'a completed Social retake keeps completion');
select is(public.is_module_unlocked('executable-file'), true, 'a later Social retake cannot re-lock Malicious Document');

create temporary table executable_attempt as select public.begin_verified_practice_attempt('executable-file') as id;
select is((select score::integer from public.complete_verified_practice_attempt((select id from executable_attempt),
  '["inspect:source","inspect:filename","verify_official_channel","choose:open"]'::jsonb)), 67,
  'opening the simulated file is a completed unsuccessful attempt');
select is((select outcome from public.practice_attempts where id=(select id from executable_attempt)), 'unsafe',
  'the database persists the unsuccessful document outcome');
select is((select completed_at is not null from public.practice_attempts where id=(select id from executable_attempt)), true,
  'an unsuccessful document attempt stores its completion time');

create temporary table executable_retry as select public.begin_verified_practice_attempt('executable-file') as id;
select is((select score::integer from public.complete_verified_practice_attempt((select id from executable_retry),
  '["inspect:source","inspect:filename","verify_official_channel","choose:report"]'::jsonb)), 100,
  'the required inspection, official check, and report decision produce 100%');
select is((select verify_practised from public.user_module_progress where user_id=(select user_id from fixture_user) and module_id='executable-file'), true,
  'the server records the verification habit from the official-channel check');

create temporary table executable_failed_retake as select public.begin_verified_practice_attempt('executable-file') as id;
select score from public.complete_verified_practice_attempt((select id from executable_failed_retake),
  '["inspect:source","inspect:filename","verify_official_channel","choose:open"]'::jsonb);
select is((select verified_score::integer from public.user_module_progress where user_id=(select user_id from fixture_user) and module_id='executable-file'), 100,
  'a failed Malicious Document retake cannot lower the perfect score');
select is(public.is_module_unlocked('executable-file'), true, 'a failed document retake does not erase completed access');
create temporary table invalid_executable_sequence as select public.begin_verified_practice_attempt('executable-file') as id;
select throws_ok($$select public.complete_verified_practice_attempt((select id from invalid_executable_sequence),
  '["verify_official_channel","inspect:source","choose:report"]'::jsonb)$$,
  '22023', 'INVALID_DECISION_SEQUENCE', 'out-of-order decision identifiers are rejected server-side');

select throws_ok($$update public.user_module_progress set verified_score=0 where user_id=(select user_id from fixture_user) and module_id='social-engineering'$$,
  '42501', 'MODULE_COMPLETION_REQUIRES_VERIFIED_ATTEMPT', 'direct client score mutation is rejected');
select throws_ok($$update public.practice_attempts set outcome='safe' where id=(select id from executable_attempt)$$,
  '42501', 'ATTEMPT_COMPLETION_REQUIRES_VERIFIED_RESULT', 'direct client attempt outcome mutation is rejected');
select throws_ok($$insert into public.practice_events(attempt_id,event_type,stage,metadata_json)
  values ((select id from executable_attempt),'module_completed','complete','{"score":100,"perfect":true}'::jsonb)$$,
  '42501', 'MODULE_COMPLETION_EVENT_REQUIRES_VERIFIED_RESULT', 'direct completion-event insertion is rejected');

select * from finish();
rollback;
