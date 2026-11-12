-- Prevent browser writes from bypassing user_achievements through the
-- denormalized profiles.badges array.

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

  perform set_config('alethia.badge_sync', 'on', true);
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
  perform set_config('alethia.badge_sync', 'off', true);

  return null;
end;
$$;

create or replace function public.protect_profile_badge_projection()
returns trigger
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
begin
  if new.badges is distinct from old.badges
     and current_setting('alethia.badge_sync', true) is distinct from 'on'
     and coalesce(auth.role(), current_user) in ('anon', 'authenticated') then
    raise exception 'PROFILE_BADGES_DATABASE_MANAGED' using errcode = '42501';
  end if;
  return new;
end;
$$;

drop trigger if exists profiles_protect_badges on public.profiles;
create trigger profiles_protect_badges
  before update on public.profiles
  for each row execute function public.protect_profile_badge_projection();

revoke all on function public.sync_profile_badges() from public;
revoke all on function public.protect_profile_badge_projection() from public;

comment on function public.protect_profile_badge_projection() is
  'Allows profiles.badges changes only through the user_achievements synchronization path.';
