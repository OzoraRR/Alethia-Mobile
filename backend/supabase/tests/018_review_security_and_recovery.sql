begin;
select no_plan();
create temporary table review_fixture as select gen_random_uuid() as user_id, gen_random_uuid() as report_id;
create temporary table review_attempts (module_id text, attempt_id uuid);
grant select,insert on review_fixture,review_attempts to authenticated;
insert into auth.users(id,email,raw_user_meta_data,raw_app_meta_data)
select user_id,'review@example.invalid','{"username":"review_owner"}', '{"provider":"email"}' from review_fixture;
select set_config('request.jwt.claims',jsonb_build_object('sub',(select user_id from review_fixture),'role','authenticated','is_anonymous',false)::text,true);
insert into public.practice_reports(id,source,title,category,channel,pattern,evidence,why_risky)
select report_id,'manual','Review regression report','SMS phishing','Text message','Urgency',
  'Synthetic evidence for the review regression.','Synthetic explanation of the risk.' from review_fixture;
set local role authenticated;
select throws_ok($$update public.practice_reports set investigator_verdict='valid' where id=(select report_id from review_fixture)$$,
  '42501','REPORT_VERDICT_REQUIRES_INVESTIGATOR_RPC','owners cannot forge the verdict cache');
select throws_ok($$insert into public.practice_reports(source,title,category,channel,pattern,evidence,why_risky,investigator_verdict)
  values('manual','Forged verdict','SMS phishing','Text message','Urgency','Synthetic evidence long enough.','Synthetic risk long enough.','valid')$$,
  '42501','REPORT_VERDICT_REQUIRES_INVESTIGATOR_RPC','insert cannot seed a forged verdict');
select throws_ok($$insert into public.report_signals(report_id,user_id) select report_id,user_id from review_fixture$$,
  '42501',null,'a student cannot bypass signal eligibility');
insert into public.report_investigation_notes(report_id,user_id,author_role,text)
select report_id,user_id,'investigator','Synthetic student note with a forged role.' from review_fixture;
select is((select author_role from public.report_investigation_notes where report_id=(select report_id from review_fixture)),
  'student','note roles are derived from protected progress');
select throws_ok($$select public.delete_my_account('HAPUS AKUN SAYA')$$,
  '42501','ACCOUNT_DELETION_REQUIRES_PREPARATION','direct deletion requires preparation');
insert into review_attempts select 'courier-sms',public.begin_verified_practice_attempt('courier-sms');
select is((select score::integer from public.complete_verified_practice_attempt((select attempt_id from review_attempts where module_id='courier-sms'),
  '["assess:sender_unverified","assess:link_suspicious","verify_official_channel","choose:report_delete"]')),100,'perfect completion succeeds');
select is((select score::integer from public.complete_verified_practice_attempt((select attempt_id from review_attempts where module_id='courier-sms'),
  '["choose:open_link"]')),100,'retry returns the original result instead of changing it');
select is((select count(*)::integer from public.practice_events where attempt_id=(select attempt_id from review_attempts where module_id='courier-sms')
  and event_type='module_completed'),1,'retry does not duplicate completion events');
insert into review_attempts select 'social-engineering',public.begin_verified_practice_attempt('social-engineering');
select is((select score from public.complete_verified_practice_attempt((select attempt_id from review_attempts where module_id='social-engineering'),
  '["artifact:visual","artifact:routine","mitigation:limit","complete:reconstruction"]')),null::smallint,'social completion remains unscored');
select is((select score from public.complete_verified_practice_attempt((select attempt_id from review_attempts where module_id='social-engineering'),
  '[]')),null::smallint,'unscored result can also be recovered idempotently');
insert into public.report_signals(report_id,user_id) select report_id,user_id from review_fixture;
select is((select signal_score from public.practice_reports where id=(select report_id from review_fixture)),1,'investigators can signal');
select is(public.cast_report_verdict((select report_id from review_fixture),'valid','Synthetic reason')->>'valid','1','trusted verdict RPC still updates the cache');
select is(jsonb_array_length(public.export_my_data()->'report_verdicts'),1,'export includes investigator votes and reasons');
reset role;
grant select,insert on storage.objects to authenticated;
insert into storage.objects(bucket_id,name,owner)
select 'avatars',user_id::text||'/abandoned.png',user_id from review_fixture;
set local role authenticated;
select is(cardinality(public.prepare_account_deletion('HAPUS AKUN SAYA')),1,'preparation returns historical avatar paths');
select is(public.account_accepts_avatar_uploads(),false,'preparation freezes avatar uploads');
select throws_ok($$insert into storage.objects(bucket_id,name,owner)
  select 'avatars',user_id::text||'/late-upload.png',user_id from review_fixture$$,
  '42501',null,'Storage RLS rejects new uploads after deletion preparation');
select throws_ok($$select public.delete_my_account('HAPUS AKUN SAYA')$$,
  '23514','ACCOUNT_AVATARS_REMAIN','deletion refuses to orphan a public avatar');
reset role;
-- Simulate successful Storage API removal in this SQL-only fixture.
set local storage.allow_delete_query = 'true';
delete from storage.objects where owner=(select user_id from review_fixture);
reset storage.allow_delete_query;
set local role authenticated;
select is(public.delete_my_account('HAPUS AKUN SAYA')->>'reports_anonymised','1','deletion returns its actual anonymized report count');
reset role;
select is((select user_id from public.practice_reports where id=(select report_id from review_fixture)),null::uuid,'anonymized report survives');

insert into public.admin_accounts(username,password_hash)
values('review_admin',extensions.crypt('synthetic-review-password',extensions.gen_salt('bf',4)));
select is((select error_code from public.admin_login('review_admin',repeat('x',200),'')),
  'INVALID_ADMIN_CREDENTIALS','oversized bcrypt input is recorded without rolling back');
update public.admin_login_attempts set failure_count=0
  where identity_hash=encode(extensions.digest('review_admin','sha256'),'hex');
do $$begin for i in 1..5 loop perform public.admin_login('review_admin','wrong',i::text); end loop; end$$;
select is((select error_code from public.admin_login('review_admin','wrong','rotated-ip')),'ADMIN_LOGIN_RATE_LIMITED',
  'failed logins persist and rotating forwarding headers cannot bypass the limiter');
select is((select failure_count from public.admin_login_attempts
  where identity_hash=encode(extensions.digest('review_admin','sha256'),'hex')),5,'counter records every committed failure');
update public.admin_login_attempts set window_started_at=now()-interval '16 minutes'
  where identity_hash=encode(extensions.digest('review_admin','sha256'),'hex');
select is((select error_code from public.admin_login('review_admin','synthetic-review-password','')),
  null::text,'login succeeds after the limiting window expires');
select is((select failure_count from public.admin_login_attempts
  where identity_hash=encode(extensions.digest('review_admin','sha256'),'hex')),0,'successful login resets the failure count');
select is((select error_code from public.admin_login('unknown_review_admin','wrong','')),
  'INVALID_ADMIN_CREDENTIALS','unknown administrator receives a generic rejection');
select is((select count(*)::integer from public.admin_login_attempts
  where identity_hash=encode(extensions.digest('unknown_review_admin','sha256'),'hex')),0,'unknown names do not allocate counter rows');
select * from finish();
rollback;
