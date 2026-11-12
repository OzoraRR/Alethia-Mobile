-- Fix PL/pgSQL name ambiguity in record_daily_activity after schema lint.

create or replace function public.record_daily_activity(
  requested_timezone text default null
)
returns table (
  quest_date date,
  current_streak integer,
  longest_streak integer,
  points integer,
  newly_assigned_quests integer
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  current_user_id uuid := (select auth.uid());
  resolved_timezone text;
  resolved_quest_date date;
  assigned_count integer;
  previous_streak public.user_streaks%rowtype;
  next_streak_value integer;
  next_longest_value integer;
  total_points integer;
begin
  if current_user_id is null then
    raise exception 'AUTHENTICATION_REQUIRED' using errcode = '42501';
  end if;

  select coalesce(
    nullif(btrim(requested_timezone), ''),
    profile.timezone,
    'Asia/Jakarta'
  )
  into resolved_timezone
  from public.profiles as profile
  where profile.id = current_user_id;

  if resolved_timezone is null then
    resolved_timezone := 'Asia/Jakarta';
  end if;

  if not exists (
    select 1
    from pg_timezone_names
    where name = resolved_timezone
  ) then
    raise exception 'INVALID_TIMEZONE' using errcode = '22023';
  end if;

  update public.profiles as profile
  set timezone = resolved_timezone
  where profile.id = current_user_id;

  resolved_quest_date := (now() at time zone resolved_timezone)::date;

  select *
  into previous_streak
  from public.user_streaks
  where user_id = current_user_id
  for update;

  if not found then
    next_streak_value := 1;
    next_longest_value := 1;
    insert into public.user_streaks (
      user_id,
      current_streak,
      longest_streak,
      freezes_remaining,
      last_active_date,
      updated_at
    )
    values (
      current_user_id,
      next_streak_value,
      next_longest_value,
      1,
      resolved_quest_date,
      now()
    );
  elsif previous_streak.last_active_date = resolved_quest_date then
    next_streak_value := previous_streak.current_streak;
    next_longest_value := previous_streak.longest_streak;
    update public.user_streaks as streak
    set updated_at = now()
    where streak.user_id = current_user_id;
  else
    next_streak_value := case
      when previous_streak.last_active_date = resolved_quest_date - 1
        then previous_streak.current_streak + 1
      else 1
    end;
    next_longest_value := greatest(previous_streak.longest_streak, next_streak_value);
    update public.user_streaks as streak
    set current_streak = next_streak_value,
        longest_streak = next_longest_value,
        last_active_date = resolved_quest_date,
        updated_at = now()
    where streak.user_id = current_user_id;
  end if;

  assigned_count := public.ensure_daily_quests_for_user(current_user_id, resolved_quest_date);

  update public.user_daily_quests as assignment
  set status = case
        when assignment.progress_value >= assignment.target_value then 'completed'::text
        else 'in_progress'::text
      end,
      progress_value = assignment.target_value,
      completed_at = coalesce(assignment.completed_at, now()),
      updated_at = now()
  where assignment.user_id = current_user_id
    and assignment.quest_date = resolved_quest_date
    and assignment.quest_id = 'daily-login'
    and assignment.status not in ('completed', 'claimed');

  select profile.points
  into total_points
  from public.profiles as profile
  where profile.id = current_user_id;

  return query
  select
    resolved_quest_date,
    next_streak_value,
    next_longest_value,
    coalesce(total_points, 0),
    assigned_count;
end;
$$;

revoke all on function public.record_daily_activity(text) from public;
grant execute on function public.record_daily_activity(text) to authenticated;
