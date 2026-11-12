-- Keep profiles.badges as a database-managed projection of the authoritative
-- user_achievements table.

create or replace function public.sync_profile_badges()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  affected_user_id uuid;
begin
  if tg_op = 'DELETE' then
    affected_user_id := old.user_id;
  else
    affected_user_id := new.user_id;
  end if;

  update public.profiles as profile
  set badges = coalesce(
    (
      select array_agg(achievement.code order by achievement.awarded_at, achievement.code)
      from public.user_achievements as achievement
      where achievement.user_id = affected_user_id
    ),
    '{}'::text[]
  )
  where profile.id = affected_user_id;

  return null;
end;
$$;

drop trigger if exists user_achievements_sync_profile_badges on public.user_achievements;
create trigger user_achievements_sync_profile_badges
  after insert or delete on public.user_achievements
  for each row execute function public.sync_profile_badges();

update public.profiles as profile
set badges = coalesce(
  (
    select array_agg(achievement.code order by achievement.awarded_at, achievement.code)
    from public.user_achievements as achievement
    where achievement.user_id = profile.id
  ),
  '{}'::text[]
);

revoke all on function public.sync_profile_badges() from public;

comment on column public.profiles.badges is
  'Database-managed cache of public.user_achievements codes for dashboard/profile display.';
