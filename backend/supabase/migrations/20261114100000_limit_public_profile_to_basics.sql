-- Keep public profiles discoverable, but do not reveal report or investigation
-- activity through the profile projection. Public avatars are configured
-- separately in Storage and are not changed by this migration.
create or replace function public.get_public_profile(requested_username text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  target_id uuid;
  result jsonb;
begin
  select profile.id
  into target_id
  from public.profiles as profile
  where profile.username is not null
    and lower(profile.username) = lower(btrim(coalesce(requested_username, '')));

  if target_id is null then
    raise exception 'PROFILE_NOT_FOUND' using errcode = '22023';
  end if;

  select jsonb_build_object(
    'username', profile.username,
    'modules_completed', profile.modules_completed,
    'mastery', profile.mastery,
    'badges', coalesce((
      select jsonb_agg(badge.badge_code order by badge.badge_code)
      from public.user_profile_badges as badge
      where badge.user_id = target_id
        and badge.selected = true
    ), '[]'::jsonb)
  )
  into result
  from public.profiles as profile
  where profile.id = target_id;

  return result;
end;
$$;

comment on function public.get_public_profile(text) is
  'Minimal public profile: username, learning progress, mastery and selected badges. Report and investigation activity, email, points, streaks and locale are not exposed.';
