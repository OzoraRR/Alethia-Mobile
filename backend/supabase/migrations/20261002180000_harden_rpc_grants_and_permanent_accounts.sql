-- The publishable API key is intentionally public. PostgreSQL grants, RLS,
-- and the caller's JWT must therefore be the security boundary.

-- SECURITY DEFINER functions must not inherit a role-mutable search_path.
-- This trigger function already schema-qualifies auth.role(); the remaining
-- names it uses are PostgreSQL built-ins.
alter function public.protect_profile_identity() set search_path = pg_catalog;

-- Avatar images are intentionally public. Object writes remain owner-scoped,
-- and anonymous Auth identities must not be able to create or replace them.
update storage.buckets
set public = true,
    file_size_limit = 2097152,
    allowed_mime_types = array['image/png', 'image/jpeg', 'image/webp']
where id = 'avatars';

drop policy if exists avatars_require_permanent_insert on storage.objects;
create policy avatars_require_permanent_insert on storage.objects
  as restrictive for insert to authenticated
  with check (
    bucket_id <> 'avatars'
    or (select auth.jwt() ->> 'is_anonymous' = 'false')
  );

drop policy if exists avatars_require_permanent_update on storage.objects;
create policy avatars_require_permanent_update on storage.objects
  as restrictive for update to authenticated
  using (
    bucket_id <> 'avatars'
    or (select auth.jwt() ->> 'is_anonymous' = 'false')
  )
  with check (
    bucket_id <> 'avatars'
    or (select auth.jwt() ->> 'is_anonymous' = 'false')
  );

drop policy if exists avatars_require_permanent_delete on storage.objects;
create policy avatars_require_permanent_delete on storage.objects
  as restrictive for delete to authenticated
  using (
    bucket_id <> 'avatars'
    or (select auth.jwt() ->> 'is_anonymous' = 'false')
  );

-- The earlier community-read policies are extended to writes as well. These
-- restrictive policies compose with existing ownership policies using AND.
do $$
declare
  table_name text;
  policy_name text;
begin
  foreach table_name in array array[
    'profiles',
    'practice_attempts',
    'practice_events',
    'user_module_progress',
    'user_streaks',
    'user_achievements',
    'user_daily_streaks',
    'user_daily_quests',
    'user_point_ledger',
    'user_profile_badges',
    'notifications',
    'practice_reports',
    'report_signals',
    'report_investigation_notes',
    'report_verdicts',
    'report_deletions'
  ] loop
    policy_name := table_name || '_require_permanent_account';
    execute format('drop policy if exists %I on public.%I', policy_name, table_name);
    execute format(
      'create policy %I on public.%I as restrictive for all to authenticated using ((select auth.jwt() ->> ''is_anonymous'' = ''false'')) with check ((select auth.jwt() ->> ''is_anonymous'' = ''false''))',
      policy_name,
      table_name
    );
  end loop;
end;
$$;

-- Fail closed for PostgREST RPC execution. Functions called by triggers or
-- other SECURITY DEFINER functions continue to work as their owner; direct
-- clients receive only the narrow allow-list below.
revoke execute on all functions in schema public from public, anon, authenticated;

grant execute on function public.get_dashboard_state() to authenticated;
grant execute on function public.get_module_access() to authenticated;
grant execute on function public.get_verified_module_access() to authenticated;
grant execute on function public.get_module_result(text) to authenticated;
grant execute on function public.begin_verified_practice_attempt(text) to authenticated;
grant execute on function public.complete_verified_practice_attempt(uuid, jsonb) to authenticated;
grant execute on function public.record_daily_activity(text) to authenticated;
grant execute on function public.claim_daily_quest(text, date) to authenticated;
grant execute on function public.mark_notification_read(uuid) to authenticated;
grant execute on function public.change_username(text) to authenticated;
grant execute on function public.set_profile_badge(text, boolean) to authenticated;
grant execute on function public.cast_report_verdict(uuid, text, text) to authenticated;
grant execute on function public.export_my_data() to authenticated;
grant execute on function public.delete_my_account(text) to authenticated;

-- Public profiles expose only the intentionally public profile projection.
grant execute on function public.get_public_profile(text) to anon, authenticated;

-- Username-to-email resolution is needed only during a server-side login
-- handshake. The browser must never be able to enumerate account emails.
grant execute on function public.get_profile_email_by_username(text) to service_role;

-- Restore only the server/maintenance functions that had explicit service
-- role use. Never grant these cross-user helpers to browser roles.
grant execute on function public.assign_daily_quests_for_all_users() to service_role;
grant execute on function public.retire_inactive_quest_assignments(date) to service_role;
grant execute on function public.evaluate_achievements(uuid) to service_role;
grant execute on function public.award_module_completion_points(uuid, text) to service_role;

-- Admin RPCs retain their independent hashed-session-token checks, but are no
-- longer callable using the public key. The bootstrap/password initialization
-- functions deliberately remain owner-only.
do $$
declare
  function_signature text;
begin
  for function_signature in
    select format(
      '%I.%I(%s)',
      namespace.nspname,
      procedure.proname,
      pg_get_function_identity_arguments(procedure.oid)
    )
    from pg_proc as procedure
    join pg_namespace as namespace on namespace.oid = procedure.pronamespace
    where namespace.nspname = 'public'
      and procedure.prokind = 'f'
      and procedure.proname like 'admin\_%' escape '\'
      and procedure.proname not in ('admin_set_password', 'admin_bootstrap_password')
  loop
    execute format('revoke all on function %s from public, anon, authenticated', function_signature);
    execute format('grant execute on function %s to service_role', function_signature);
  end loop;
end;
$$;

revoke all on function public.write_admin_audit(text, text, text, text, jsonb)
  from public, anon, authenticated, service_role;
revoke all on function public.profile_username_exists(text)
  from public, anon, authenticated, service_role;
