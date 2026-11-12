-- Evaluate already-existing progress/streak/report history once so users are
-- not required to repeat an activity just to receive earned achievements.

do $$
declare
  user_row record;
begin
  for user_row in
    select distinct user_id
    from public.user_module_progress
    where status = 'completed'
  loop
    perform public.award_progress_achievements(user_row.user_id);
  end loop;

  for user_row in
    select user_id
    from public.user_streaks
    where current_streak >= 7
  loop
    perform public.award_streak_achievement(user_row.user_id, user_row.current_streak);
  end loop;

  for user_row in
    select distinct user_id
    from public.practice_reports
  loop
    perform public.award_report_achievements(user_row.user_id);
  end loop;
end;
$$;
