begin;
select no_plan();
create temporary table learning_fixture as select gen_random_uuid() as user_id;
insert into auth.users(instance_id,id,aud,role,email,email_confirmed_at,created_at,updated_at,raw_app_meta_data,raw_user_meta_data)
select '00000000-0000-0000-0000-000000000000',user_id,'authenticated','authenticated','learning-recovery@example.invalid',now(),now(),now(),
 '{"provider":"email","providers":["email"]}'::jsonb,'{"username":"learning_recovery"}'::jsonb from learning_fixture;
insert into public.profiles(id,username,email) select user_id,'learning_recovery','learning-recovery@example.invalid' from learning_fixture on conflict(id) do nothing;
select set_config('request.jwt.claims',json_build_object('sub',(select user_id::text from learning_fixture),'role','authenticated','is_anonymous',false)::text,true);
select public.record_daily_activity('Asia/Jakarta');
create temporary table initial_points as select points from public.profiles where id=(select user_id from learning_fixture);
select ok(not has_function_privilege('anon','public.get_learning_sessions()','execute'),'guest cannot read account sessions');
select ok(not has_table_privilege('authenticated','public.learning_sessions','INSERT'),'client cannot insert arbitrary account sessions');
select throws_ok($$select public.open_learning_session('social-engineering')$$,'42501','MODULE_LOCKED','cannot open a locked lesson');
create temporary table draft as select public.open_learning_session('courier-sms') as value;
select is(public.open_learning_session('courier-sms')->>'attempt_id',(select value->>'attempt_id' from draft),'opening twice resumes same attempt');
select is(jsonb_array_length(public.get_learning_sessions()),1,'account reads recovered lesson');
select is((public.save_learning_session((select (value->>'attempt_id')::uuid from draft),0,'{"stage":2}') ->>'revision')::integer,1,'checkpoint increments revision');
select is((public.save_learning_session((select (value->>'attempt_id')::uuid from draft),0,'{"stage":2}') ->>'revision')::integer,1,'response-loss retry is idempotent');
select throws_ok($$select public.save_learning_session((select (value->>'attempt_id')::uuid from draft),0,'{"stage":3}')$$,'40001','SESSION_REVISION_CONFLICT','stale device cannot overwrite new checkpoint');
select throws_ok($$select public.save_learning_session((select (value->>'attempt_id')::uuid from draft),1,'[]')$$,'22023','INVALID_LEARNING_STATE','reject malformed snapshot');
select public.save_learning_session((select (value->>'attempt_id')::uuid from draft),1,'{"stage":6,"score":100}');
select is(public.is_module_unlocked('social-engineering'),false,'forged UI completion does not unlock module 2');
select is((select score from public.complete_verified_practice_attempt((select (value->>'attempt_id')::uuid from draft),
 '["assess:sender_unverified","assess:link_suspicious","verify_official_channel","choose:report_delete"]')),100::smallint,'module 1 scored by server');
select is(public.is_module_unlocked('social-engineering'),true,'verified module 1 unlocks module 2');
create temporary table point_snapshot as select points from public.profiles where id=(select user_id from learning_fixture);
select score from public.complete_verified_practice_attempt((select (value->>'attempt_id')::uuid from draft),
 '["assess:sender_unverified","assess:link_suspicious","verify_official_channel","choose:report_delete"]');
select is((select points from public.profiles where id=(select user_id from learning_fixture)),(select points from point_snapshot),'retry result does not duplicate points');
create temporary table social_draft as select public.open_learning_session('social-engineering') as value;
select is((select score from public.complete_verified_practice_attempt((select (value->>'attempt_id')::uuid from social_draft),
 '["artifact:visual","artifact:career","mitigation:verify","complete:reconstruction"]')),null::smallint,'module 2 completes without numeric score');
select is(public.is_module_unlocked('executable-file'),true,'module 2 unlocks module 3');
create temporary table file_draft as select public.open_learning_session('executable-file') as value;
select is((select score from public.complete_verified_practice_attempt((select (value->>'attempt_id')::uuid from file_draft),
 '["inspect:filename","inspect:extension","verify_official_channel","choose:report"]')),100::smallint,'module 3 server result');
select is((select count(*)::integer from public.user_module_progress where user_id=(select user_id from learning_fixture) and status='completed'),3,'all three completions persisted');
select is((select points from public.profiles where id=(select user_id from learning_fixture))-(select points from initial_points),100,'three first completions grant exactly 100 points');
select ok(exists(select 1 from public.user_achievements where user_id=(select user_id from learning_fixture)),'completion updates achievements');
select ok(exists(select 1 from public.user_daily_quests where user_id=(select user_id from learning_fixture) and progress_value>0),'daily quests advance');
select set_config('request.jwt.claims',json_build_object('sub',gen_random_uuid()::text,'role','authenticated','is_anonymous',false)::text,true);
select is(jsonb_array_length(public.get_learning_sessions()),0,'different account sees no recovered sessions');
select throws_ok($$select public.save_learning_session((select (value->>'attempt_id')::uuid from draft),2,'{"stage":3}')$$,'42501','SESSION_NOT_FOUND','different account cannot change checkpoint');
select * from finish();
rollback;
