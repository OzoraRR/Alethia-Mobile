-- Umbrella concerns: one dashboard read, scheduled quest assignment, and admin
-- credential rotation.
--
-- The dashboard previously assembled itself from five independent client
-- queries (profile, module progress, streaks, quests, notifications), each of
-- which could land at a different point in time. get_dashboard_state replaces
-- them with a single consistent snapshot.
--
-- The admin launch password was committed in cleartext next to its own hash in
-- 20260925050000_profile_edit_admin.sql. That file has been edited to seed a
-- random value instead, and this migration rotates the live account.

-- ---------------------------------------------------------------------------
-- 1. get_dashboard_state
-- ---------------------------------------------------------------------------

create or replace function public.get_dashboard_state()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  current_user_id uuid := (select auth.uid());
  resolved_timezone text;
  resolved_quest_date date;
  profile_row public.profiles%rowtype;
  practice_streak public.user_streaks%rowtype;
  daily_streak public.user_daily_streaks%rowtype;
  module_rows jsonb;
  quest_rows jsonb;
  achievement_rows jsonb;
  notification_count integer;
  unread_count integer;
  pending_report_count integer;
begin
  if current_user_id is null then
    raise exception 'AUTHENTICATION_REQUIRED' using errcode = '42501';
  end if;

  select *
  into profile_row
  from public.profiles as profile
  where profile.id = current_user_id;

  if profile_row.id is null then
    raise exception 'PROFILE_NOT_FOUND' using errcode = '23503';
  end if;

  resolved_timezone := coalesce(profile_row.timezone, 'Asia/Jakarta');
  resolved_quest_date := (now() at time zone resolved_timezone)::date;

  select *
  into practice_streak
  from public.user_streaks as streak
  where streak.user_id = current_user_id;

  select *
  into daily_streak
  from public.user_daily_streaks as streak
  where streak.user_id = current_user_id;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'module_id', module.id,
        'position', module.position,
        'accessState', public.module_access_state(
          current_user_id,
          module.position,
          coalesce(progress.status, 'not_started')
        ),
        'status', coalesce(progress.status, 'not_started'),
        'progressPercentage', coalesce(progress.progress_percentage, 0),
        'score', progress.score,
        'startedAt', progress.started_at,
        'completedAt', progress.completed_at,
        'notifiedAt', progress.notified_at
      )
      order by module.position
    ),
    '[]'::jsonb
  )
  into module_rows
  from public.modules as module
  left join public.user_module_progress as progress
    on progress.module_id = module.id
   and progress.user_id = current_user_id
  where module.is_active = true
    and module.is_published = true
    and module.content_key is not null;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', assignment.quest_id,
        'questDate', assignment.quest_date,
        'status', assignment.status,
        'progressValue', assignment.progress_value,
        'targetValue', assignment.target_value,
        'rewardPoints', assignment.reward_points,
        'completedAt', assignment.completed_at,
        'claimedAt', assignment.claimed_at,
        'title', quest.title,
        'description', quest.description,
        'questType', quest.quest_type,
        'position', quest.position
      )
      order by quest.position, assignment.quest_id
    ),
    '[]'::jsonb
  )
  into quest_rows
  from public.user_daily_quests as assignment
  left join public.daily_quests as quest on quest.id = assignment.quest_id
  where assignment.user_id = current_user_id
    and assignment.quest_date = resolved_quest_date;

  select coalesce(
    jsonb_agg(
      jsonb_build_object('code', achievement.code, 'awardedAt', achievement.awarded_at)
      order by achievement.awarded_at desc
    ),
    '[]'::jsonb
  )
  into achievement_rows
  from public.user_achievements as achievement
  where achievement.user_id = current_user_id;

  select
    count(*)::integer,
    count(*) filter (where notification.is_read = false)::integer
  into notification_count, unread_count
  from public.notifications as notification
  where notification.user_id = current_user_id;

  select count(*)::integer
  into pending_report_count
  from public.practice_reports as report
  where report.user_id = current_user_id
    and report.review_status = 'queued';

  return jsonb_build_object(
    'questDate', resolved_quest_date,
    'timezone', resolved_timezone,
    'profile', jsonb_build_object(
      'id', profile_row.id,
      'username', profile_row.username,
      'displayName', profile_row.display_name,
      'preferredLocale', profile_row.preferred_locale,
      'points', profile_row.points,
      'modulesCompleted', profile_row.modules_completed,
      'mastery', profile_row.mastery,
      'badges', to_jsonb(profile_row.badges)
    ),
    'practiceStreak', jsonb_build_object(
      'current', coalesce(practice_streak.current_streak, 0),
      'longest', coalesce(practice_streak.longest_streak, 0),
      'freezesRemaining', coalesce(practice_streak.freezes_remaining, 0),
      'lastQualifyingDate', practice_streak.last_qualifying_date
    ),
    'dailyStreak', jsonb_build_object(
      'current', coalesce(daily_streak.current_streak, 0),
      'longest', coalesce(daily_streak.longest_streak, 0),
      'lastActiveDate', daily_streak.last_active_date
    ),
    'modules', module_rows,
    'quests', quest_rows,
    'achievements', achievement_rows,
    'notifications', jsonb_build_object(
      'total', notification_count,
      'unread', unread_count
    ),
    'reports', jsonb_build_object(
      'pending', pending_report_count
    )
  );
end;
$$;

revoke all on function public.get_dashboard_state() from public;
grant execute on function public.get_dashboard_state() to authenticated;

comment on function public.get_dashboard_state() is
  'Single consistent snapshot of profile, module access, streaks, daily quests, achievements and notification counts.';

-- ---------------------------------------------------------------------------
-- 2. Set-based daily assignment + pg_cron
-- ---------------------------------------------------------------------------

-- The row-at-a-time loop was O(quests * users) round trips inside a single
-- transaction. One INSERT ... SELECT does the same work.
create or replace function public.assign_daily_quests_for_all_users()
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  inserted_count integer;
begin
  insert into public.user_daily_quests (
    user_id,
    quest_date,
    quest_id,
    status,
    progress_value,
    target_value,
    reward_points,
    updated_at
  )
  select
    profile.id,
    (now() at time zone profile.timezone)::date,
    quest.id,
    'not_started',
    0,
    quest.target_value,
    quest.reward_points,
    now()
  from public.profiles as profile
  cross join public.daily_quests as quest
  where quest.is_active = true
  on conflict (user_id, quest_date, quest_id) do nothing;

  get diagnostics inserted_count = row_count;
  return inserted_count;
end;
$$;

revoke all on function public.assign_daily_quests_for_all_users() from public;
grant execute on function public.assign_daily_quests_for_all_users() to service_role;

-- pg_cron is optional. The failure modes are not limited to a missing control
-- file: an unloadable shared object raises internal_error, and a version whose
-- name is not on the allow list raises feature_not_supported. Any of those would
-- abort the migration if not caught, so the handler is deliberately broad.
--
-- Lazy assignment already runs on the user's first activity of the day, so where
-- pg_cron is unavailable the lazy path is the only path and nothing breaks. The
-- scheduled job just makes the rows exist ahead of time.
do $$
begin
  create extension if not exists pg_cron;
exception
  when others then
    raise notice
      'pg_cron is unavailable (%). Daily quest assignment stays lazy, which is functionally equivalent.',
      sqlerrm;
end;
$$;

-- The cron calls go through EXECUTE so the `cron` schema is never resolved at
-- plan time. `cron` is not on this migration's search_path, so a statically
-- parsed reference fails to plan even on an instance where pg_cron is installed.
do $$
begin
  execute $cron$
    select cron.unschedule(job.jobid)
    from cron.job as job
    where job.jobname = 'alethia-assign-daily-quests'
  $cron$;

  execute $cron$
    select cron.schedule(
      'alethia-assign-daily-quests',
      '7 0 * * *',
      'select public.assign_daily_quests_for_all_users()'
    )
  $cron$;

  raise notice 'Scheduled alethia-assign-daily-quests at 00:07 UTC.';
exception
  when others then
    raise notice 'Could not schedule daily quest assignment (%); the lazy path still applies.', sqlerrm;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Admin credential rotation
-- ---------------------------------------------------------------------------

-- rotated_at marks that the launch credential has been replaced by a generated
-- value. Its presence is what makes the rotation below happen exactly once.
--
-- Declared here as well as in 20260925050000, and that duplication is
-- deliberate. That migration is already applied on any existing project, and an
-- edit to an applied file never re-runs. Relying on it alone means this
-- function reads a column that does not exist and the whole file aborts on the
-- first push. `if not exists` makes this a no-op on a fresh database where the
-- earlier declaration did run.
alter table public.admin_accounts
  add column if not exists rotated_at timestamptz;

comment on column public.admin_accounts.rotated_at is
  'Set when the launch credential is replaced by a generated value. Non-null means the rotation has already happened and must not repeat.';

-- The seeded credential was a cleartext string in version control. Rotate the
-- live account to a random value that exists only as a bcrypt hash, and print
-- it once so the operator can capture it from the migration output. Nothing is
-- written to the repository.
--
-- Guarded on rotated_at. An unguarded `on conflict do update` here would
-- invalidate the operator's password on every re-apply, on a partially reset
-- history, or on a restore from dump -- and the new value is only ever printed
-- as a NOTICE, which `supabase db push` does not surface. One rotation, once.
do $$
declare
  rotated_password text;
  rotated_hash text;
  already_rotated boolean;
begin
  select exists (
    select 1
    from public.admin_accounts as account
    where lower(account.username) = 'alethia'
      and account.rotated_at is not null
  )
  into already_rotated;

  if already_rotated then
    raise notice 'Admin credential was already rotated; leaving it untouched.';
    return;
  end if;

  rotated_password := encode(extensions.gen_random_bytes(18), 'base64');
  rotated_hash := extensions.crypt(rotated_password, extensions.gen_salt('bf', 12));

  update public.admin_accounts as account
  set password_hash = rotated_hash,
      rotated_at = now()
  where lower(account.username) = 'alethia';

  if not found then
    raise notice 'No Alethia admin account to rotate.';
    return;
  end if;

  raise notice
    'Admin credential rotated. username=Alethia password=%  Capture it now; it is not recoverable.',
    rotated_password;
end;
$$;

-- Escape hatch, for when the one-time rotation above did not run or its NOTICE
-- was not captured. Run it deliberately, by hand, and capture the output.
--
-- It is a function rather than a second migration on purpose: a migration that
-- can be re-applied by accident is a migration that can lock the operator out.
-- This one only runs when someone types its name.
create or replace function public.admin_bootstrap_password()
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  new_password text;
  changed_id uuid;
begin
  new_password := encode(extensions.gen_random_bytes(18), 'base64');

  update public.admin_accounts as account
  set password_hash = extensions.crypt(new_password, extensions.gen_salt('bf', 12)),
      rotated_at = now()
  where lower(account.username) = 'alethia'
  returning account.id into changed_id;

  if changed_id is null then
    raise exception 'NO_ADMIN_ACCOUNT' using errcode = 'P0002';
  end if;

  -- Any session issued against the old hash is now worthless.
  delete from public.admin_sessions as session
  where session.admin_id = changed_id;

  return new_password;
end;
$$;

-- Executable only by the table owner, which in practice means the SQL editor
-- and the CLI, not PostgREST. anon and authenticated are not granted it.
revoke all on function public.admin_bootstrap_password() from public, anon, authenticated;

comment on function public.admin_bootstrap_password() is
  'Resets the Alethia admin password to a fresh random value and returns it. Revokes every session. Run by hand; never from a migration.';

-- Ongoing rotation without a new migration. Requires the current password, so
-- a stolen session alone cannot lock the operator out.
create or replace function public.admin_rotate_password(
  requested_token text,
  current_password text,
  new_password text
)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  account_row public.admin_accounts%rowtype;
begin
  select account.*
  into account_row
  from public.admin_sessions as session
  join public.admin_accounts as account on account.id = session.admin_id
  where session.token_hash = encode(extensions.digest(requested_token, 'sha256'), 'hex')
    and session.expires_at > now()
    and account.is_active = true
  limit 1;

  if account_row.id is null then
    raise exception 'ADMIN_SESSION_REQUIRED' using errcode = '42501';
  end if;

  if account_row.password_hash is distinct from extensions.crypt(current_password, account_row.password_hash) then
    raise exception 'INVALID_ADMIN_CREDENTIALS' using errcode = 'P0001';
  end if;

  if char_length(coalesce(new_password, '')) < 12 then
    raise exception 'ADMIN_PASSWORD_TOO_SHORT' using errcode = '22023';
  end if;

  update public.admin_accounts as account
  set password_hash = extensions.crypt(new_password, extensions.gen_salt('bf', 12))
  where account.id = account_row.id;

  -- Every other session for this account is invalidated. The caller's token
  -- survives so the operator is not logged out mid-rotation.
  delete from public.admin_sessions as session
  where session.admin_id = account_row.id
    and session.token_hash is distinct from encode(extensions.digest(requested_token, 'sha256'), 'hex');

  perform public.write_admin_audit(
    requested_token,
    'admin.rotate_password',
    'admin_accounts',
    account_row.username,
    '{}'::jsonb
  );

  return true;
end;
$$;

revoke all on function public.admin_rotate_password(text, text, text) from public;
grant execute on function public.admin_rotate_password(text, text, text) to anon;

-- The launch credential in 20260925050000_profile_edit_admin.sql also reset the
-- password on every re-apply because of its on-conflict clause. That footgun
-- is gone: the seed below only inserts, and the rotation above owns the value.
