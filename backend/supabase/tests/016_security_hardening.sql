begin;
select plan(40);

select ok(
  not has_function_privilege('anon', 'public.award_points(uuid, integer, text, text, text)', 'execute'),
  'anonymous API callers cannot award points to arbitrary users'
);
select ok(
  not has_function_privilege('authenticated', 'public.award_points(uuid, integer, text, text, text)', 'execute'),
  'signed-in API callers cannot award points to arbitrary users'
);
select ok(
  not has_function_privilege('anon', 'public.advance_daily_quest(uuid, text, integer)', 'execute'),
  'anonymous API callers cannot advance quests for arbitrary users'
);
select ok(
  not has_function_privilege('authenticated', 'public.advance_daily_quest(uuid, text, integer)', 'execute'),
  'signed-in API callers cannot advance quests for arbitrary users'
);
select ok(
  not has_function_privilege('anon', 'public.evaluate_achievements(uuid)', 'execute'),
  'anonymous API callers cannot evaluate achievements for arbitrary users'
);
select ok(
  not has_function_privilege('authenticated', 'public.evaluate_achievements(uuid)', 'execute'),
  'signed-in API callers cannot evaluate achievements for arbitrary users'
);

select ok(
  not has_function_privilege('anon', 'public.admin_login(text, text, text)', 'execute'),
  'admin login RPC is not exposed to the public API key'
);
select ok(
  not has_function_privilege('authenticated', 'public.admin_login(text, text, text)', 'execute'),
  'admin login RPC is not exposed to signed-in browser users'
);
select ok(
  has_function_privilege('service_role', 'public.admin_login(text, text, text)', 'execute'),
  'server runtime can call the admin login RPC'
);
select ok(
  not has_function_privilege('anon', 'public.admin_delete_reports(text, uuid[], text)', 'execute'),
  'public API callers cannot execute admin report deletion'
);
select ok(
  has_function_privilege('service_role', 'public.admin_delete_reports(text, uuid[], text)', 'execute'),
  'server runtime can call the admin report deletion RPC'
);
select ok(
  not has_function_privilege('anon', 'public.write_admin_audit(text, text, text, text, jsonb)', 'execute'),
  'public callers cannot write admin audit rows directly'
);

select ok(
  not has_function_privilege('anon', 'public.get_profile_email_by_username(text)', 'execute'),
  'anonymous callers cannot enumerate account email addresses'
);
select ok(
  not has_function_privilege('authenticated', 'public.get_profile_email_by_username(text)', 'execute'),
  'signed-in browser users cannot enumerate account email addresses'
);
select ok(
  has_function_privilege('service_role', 'public.get_profile_email_by_username(text)', 'execute'),
  'server login handshake can resolve username to email'
);
select ok(
  not has_function_privilege('anon', 'public.profile_username_exists(text)', 'execute'),
  'anonymous callers cannot enumerate registered usernames'
);
select ok(
  not has_function_privilege('authenticated', 'public.profile_username_exists(text)', 'execute'),
  'signed-in browser users cannot enumerate registered usernames'
);

select ok(
  has_function_privilege('authenticated', 'public.get_dashboard_state()', 'execute'),
  'dashboard RPC remains available to signed-in users'
);
select ok(
  has_function_privilege('authenticated', 'public.complete_verified_practice_attempt(uuid, jsonb)', 'execute'),
  'verified practice completion remains available to signed-in users'
);
select ok(
  has_function_privilege('anon', 'public.get_public_profile(text)', 'execute'),
  'the intentionally public profile projection remains available'
);

select ok(
  (select bucket.public from storage.buckets as bucket where bucket.id = 'avatars'),
  'avatar images are configured as intentionally public objects'
);
select ok(
  exists (
    select 1 from pg_policies
    where schemaname = 'storage'
      and tablename = 'objects'
      and policyname = 'avatars_require_permanent_insert'
      and permissive = 'RESTRICTIVE'
  ),
  'avatar writes include a restrictive permanent-account requirement'
);
select ok(
  exists (
    select 1 from pg_policies
    where schemaname = 'storage'
      and tablename = 'objects'
      and policyname = 'avatars_select_own'
      and roles = array['authenticated']::name[]
  ),
  'avatar metadata selection is limited to signed-in accounts'
);
select ok(
  exists (
    select 1 from pg_policies
    where schemaname = 'storage'
      and tablename = 'objects'
      and policyname = 'avatars_require_permanent_select'
      and permissive = 'RESTRICTIVE'
  ),
  'avatar metadata selection rejects anonymous Auth identities'
);

select ok(
  exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename = 'practice_reports'
      and policyname = 'practice_reports_require_permanent_account'
      and permissive = 'RESTRICTIVE'
  ),
  'community report access requires a permanent account'
);
select ok(
  exists (
    select 1 from pg_policies
    where schemaname = 'public'
      and tablename = 'profiles'
      and policyname = 'profiles_require_permanent_account'
      and permissive = 'RESTRICTIVE'
  ),
  'profile row access requires a permanent account'
);

select ok(
  (select proconfig @> array['search_path=pg_catalog']
   from pg_proc where oid = 'public.protect_profile_identity()'::regprocedure),
  'identity protection trigger has an immutable safe search_path'
);

select ok(
  not has_function_privilege('authenticated', 'public.require_permanent_account()', 'execute'),
  'the internal permanent-account assertion is not a public RPC'
);

select set_config(
  'request.jwt.claims',
  jsonb_build_object(
    'sub', gen_random_uuid()::text,
    'role', 'authenticated',
    'is_anonymous', true
  )::text,
  true
);
set local role authenticated;

select throws_ok(
  $$select public.get_dashboard_state()$$,
  '42501', 'PERMANENT_ACCOUNT_REQUIRED',
  'anonymous Auth users cannot read the dashboard through a definer RPC'
);
select throws_ok(
  $$select * from public.get_module_access()$$,
  '42501', 'PERMANENT_ACCOUNT_REQUIRED',
  'anonymous Auth users cannot read module progress through a definer RPC'
);
select throws_ok(
  $$select public.begin_verified_practice_attempt('courier-sms')$$,
  '42501', 'PERMANENT_ACCOUNT_REQUIRED',
  'anonymous Auth users cannot create practice attempts'
);
select throws_ok(
  $$select * from public.complete_verified_practice_attempt(gen_random_uuid(), '[]'::jsonb)$$,
  '42501', 'PERMANENT_ACCOUNT_REQUIRED',
  'anonymous Auth users cannot submit practice completions'
);
select throws_ok(
  $$select * from public.record_daily_activity('Asia/Jakarta')$$,
  '42501', 'PERMANENT_ACCOUNT_REQUIRED',
  'anonymous Auth users cannot record account activity'
);
select throws_ok(
  $$select * from public.claim_daily_quest('welcome', current_date)$$,
  '42501', 'PERMANENT_ACCOUNT_REQUIRED',
  'anonymous Auth users cannot claim account rewards'
);
select throws_ok(
  $$select public.mark_notification_read(gen_random_uuid())$$,
  '42501', 'PERMANENT_ACCOUNT_REQUIRED',
  'anonymous Auth users cannot mutate notifications'
);
select throws_ok(
  $$select public.change_username('permanent_name')$$,
  '42501', 'PERMANENT_ACCOUNT_REQUIRED',
  'anonymous Auth users cannot mutate profile identity'
);
select throws_ok(
  $$select public.set_profile_badge('first-step', true)$$,
  '42501', 'PERMANENT_ACCOUNT_REQUIRED',
  'anonymous Auth users cannot mutate profile badges'
);
select throws_ok(
  $$select public.cast_report_verdict(gen_random_uuid(), 'valid', 'a reason')$$,
  '42501', 'PERMANENT_ACCOUNT_REQUIRED',
  'anonymous Auth users cannot cast community verdicts'
);
select throws_ok(
  $$select public.export_my_data()$$,
  '42501', 'PERMANENT_ACCOUNT_REQUIRED',
  'anonymous Auth users cannot export account data'
);
select throws_ok(
  $$select public.delete_my_account('DELETE')$$,
  '42501', 'PERMANENT_ACCOUNT_REQUIRED',
  'anonymous Auth users cannot invoke account deletion'
);

reset role;

select * from finish();
rollback;
