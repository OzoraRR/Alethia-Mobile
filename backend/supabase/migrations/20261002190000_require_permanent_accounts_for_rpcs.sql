-- Anonymous Auth users receive PostgreSQL's `authenticated` role. Require the
-- permanent-account claim inside SECURITY DEFINER RPC boundaries too; RLS
-- alone cannot constrain definer functions that bypass row policies.
create or replace function public.require_permanent_account()
returns void
language plpgsql
stable
security invoker
set search_path = pg_catalog
as $$
begin
  if (select auth.uid()) is null then
    raise exception 'AUTHENTICATION_REQUIRED' using errcode = '42501';
  end if;
  if (select auth.jwt() ->> 'is_anonymous') is distinct from 'false' then
    raise exception 'PERMANENT_ACCOUNT_REQUIRED' using errcode = '42501';
  end if;
end;
$$;

revoke all on function public.require_permanent_account()
  from public, anon, authenticated, service_role;

-- Retain the audited implementations as private inner functions and preserve
-- each exposed RPC's name and request/response shape.
alter function public.get_dashboard_state() rename to _get_dashboard_state_before_permanent_guard;
alter function public.get_module_access() rename to _get_module_access_before_permanent_guard;
alter function public.get_verified_module_access() rename to _get_verified_module_access_before_permanent_guard;
alter function public.get_module_result(text) rename to _get_module_result_before_permanent_guard;
alter function public.begin_verified_practice_attempt(text) rename to _begin_verified_practice_attempt_before_permanent_guard;
alter function public.complete_verified_practice_attempt(uuid, jsonb) rename to _complete_verified_practice_attempt_before_permanent_guard;
alter function public.record_daily_activity(text) rename to _record_daily_activity_before_permanent_guard;
alter function public.claim_daily_quest(text, date) rename to _claim_daily_quest_before_permanent_guard;
alter function public.mark_notification_read(uuid) rename to _mark_notification_read_before_permanent_guard;
alter function public.change_username(text) rename to _change_username_before_permanent_guard;
alter function public.set_profile_badge(text, boolean) rename to _set_profile_badge_before_permanent_guard;
alter function public.cast_report_verdict(uuid, text, text) rename to _cast_report_verdict_before_permanent_guard;
alter function public.export_my_data() rename to _export_my_data_before_permanent_guard;
alter function public.delete_my_account(text) rename to _delete_my_account_before_permanent_guard;

create function public.get_dashboard_state()
returns jsonb language plpgsql stable security definer set search_path = pg_catalog as $$
begin
  perform public.require_permanent_account();
  return public._get_dashboard_state_before_permanent_guard();
end;
$$;

create function public.get_module_access()
returns table (module_id text, module_position smallint, access_state text, progress_status text,
  progress_percentage smallint, score smallint, started_at timestamptz, completed_at timestamptz,
  notified_at timestamptz)
language plpgsql stable security definer set search_path = pg_catalog as $$
begin
  perform public.require_permanent_account();
  return query select * from public._get_module_access_before_permanent_guard();
end;
$$;

create function public.get_verified_module_access()
returns table (module_id text, module_position smallint, access_state text, progress_status text,
  progress_percentage smallint, score smallint, started_at timestamptz, completed_at timestamptz,
  notified_at timestamptz)
language plpgsql stable security definer set search_path = pg_catalog as $$
begin
  perform public.require_permanent_account();
  return query select * from public._get_verified_module_access_before_permanent_guard();
end;
$$;

create function public.get_module_result(requested_module_id text)
returns table (module_id text, module_title text, progress_status text, score smallint,
  progress_percentage smallint, started_at timestamptz, completed_at timestamptz,
  attempt_outcome text, attempt_completed_at timestamptz, analysis text, report_id uuid,
  report_title text, report_created_at timestamptz)
language plpgsql stable security definer set search_path = pg_catalog as $$
begin
  perform public.require_permanent_account();
  return query select * from public._get_module_result_before_permanent_guard(requested_module_id);
end;
$$;

create function public.begin_verified_practice_attempt(requested_module_id text)
returns uuid language plpgsql security definer set search_path = pg_catalog as $$
begin
  perform public.require_permanent_account();
  return public._begin_verified_practice_attempt_before_permanent_guard(requested_module_id);
end;
$$;

create function public.complete_verified_practice_attempt(requested_attempt_id uuid, requested_decisions jsonb)
returns table (score smallint, perfect boolean, started_at timestamptz)
language plpgsql security definer set search_path = pg_catalog as $$
begin
  perform public.require_permanent_account();
  return query select * from public._complete_verified_practice_attempt_before_permanent_guard(
    requested_attempt_id, requested_decisions
  );
end;
$$;

create function public.record_daily_activity(requested_timezone text)
returns table (quest_date date, current_streak integer, longest_streak integer, points integer,
  newly_assigned_quests integer)
language plpgsql security definer set search_path = pg_catalog as $$
begin
  perform public.require_permanent_account();
  return query select * from public._record_daily_activity_before_permanent_guard(requested_timezone);
end;
$$;

create function public.claim_daily_quest(requested_quest_id text, requested_quest_date date)
returns table (status text, reward_points integer, total_points integer)
language plpgsql security definer set search_path = pg_catalog as $$
begin
  perform public.require_permanent_account();
  return query select * from public._claim_daily_quest_before_permanent_guard(
    requested_quest_id, requested_quest_date
  );
end;
$$;

create function public.mark_notification_read(requested_notification_id uuid)
returns boolean language plpgsql security definer set search_path = pg_catalog as $$
begin
  perform public.require_permanent_account();
  return public._mark_notification_read_before_permanent_guard(requested_notification_id);
end;
$$;

create function public.change_username(requested_username text)
returns text language plpgsql security definer set search_path = pg_catalog as $$
begin
  perform public.require_permanent_account();
  return public._change_username_before_permanent_guard(requested_username);
end;
$$;

create function public.set_profile_badge(requested_badge_code text, requested_selected boolean)
returns boolean language plpgsql security definer set search_path = pg_catalog as $$
begin
  perform public.require_permanent_account();
  return public._set_profile_badge_before_permanent_guard(requested_badge_code, requested_selected);
end;
$$;

create function public.cast_report_verdict(
  requested_report_id uuid, requested_verdict text, requested_reason text
)
returns jsonb language plpgsql security definer set search_path = pg_catalog as $$
begin
  perform public.require_permanent_account();
  return public._cast_report_verdict_before_permanent_guard(
    requested_report_id, requested_verdict, requested_reason
  );
end;
$$;

create function public.export_my_data()
returns jsonb language plpgsql security definer set search_path = pg_catalog as $$
begin
  perform public.require_permanent_account();
  return public._export_my_data_before_permanent_guard();
end;
$$;

create function public.delete_my_account(requested_confirm text)
returns jsonb language plpgsql security definer set search_path = pg_catalog as $$
begin
  perform public.require_permanent_account();
  return public._delete_my_account_before_permanent_guard(requested_confirm);
end;
$$;

-- Remove inherited/default execution everywhere in the exposed API schema,
-- then re-grant only the API surface that the app actually uses.
revoke execute on all functions in schema public from public, anon, authenticated, service_role;

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
grant execute on function public.get_public_profile(text) to anon, authenticated;

-- Username-to-email resolution is private to the server login handshake.
grant execute on function public.get_profile_email_by_username(text) to service_role;

-- Existing maintenance and backfill paths use these server-only grants.
grant execute on function public.assign_daily_quests_for_all_users() to service_role;
grant execute on function public.retire_inactive_quest_assignments(date) to service_role;
grant execute on function public.evaluate_achievements(uuid) to service_role;
grant execute on function public.award_module_completion_points(uuid, text) to service_role;

-- Admin RPCs also require their hashed admin-session token. The browser can no
-- longer invoke them with the public key. The two bootstrap password functions
-- remain owner-only.
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
    execute format('revoke all on function %s from public, anon, authenticated, service_role', function_signature);
    execute format('grant execute on function %s to service_role', function_signature);
  end loop;
end;
$$;

revoke all on function public.write_admin_audit(text, text, text, text, jsonb)
  from public, anon, authenticated, service_role;
revoke all on function public.profile_username_exists(text)
  from public, anon, authenticated, service_role;
