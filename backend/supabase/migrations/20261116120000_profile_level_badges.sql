-- Award level badges from server-owned points and limit equipped badges in the
-- existing selection RPC. No client can award an achievement directly.

create or replace function public.award_level_badges()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.level >= 3 then
    insert into public.user_achievements (user_id, code)
    values (new.id, 'level_3')
    on conflict (user_id, code) do nothing;
  end if;
  if new.level >= 5 then
    insert into public.user_achievements (user_id, code)
    values (new.id, 'level_5')
    on conflict (user_id, code) do nothing;
  end if;
  return null;
end;
$$;

revoke all on function public.award_level_badges() from public;
drop trigger if exists profiles_award_level_badges on public.profiles;
create trigger profiles_award_level_badges
  after update of points on public.profiles
  for each row execute function public.award_level_badges();

insert into public.user_achievements (user_id, code)
select id, 'level_3' from public.profiles where level >= 3
on conflict (user_id, code) do nothing;
insert into public.user_achievements (user_id, code)
select id, 'level_5' from public.profiles where level >= 5
on conflict (user_id, code) do nothing;

create or replace function public.award_approved_report_badge()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.review_status = 'approved' and new.user_id is not null then
    insert into public.user_achievements (user_id, code)
    values (new.user_id, 'approved_report')
    on conflict (user_id, code) do nothing;
  end if;
  return null;
end;
$$;

revoke all on function public.award_approved_report_badge() from public;
drop trigger if exists practice_reports_award_approved_badge on public.practice_reports;
create trigger practice_reports_award_approved_badge
  after insert or update of review_status on public.practice_reports
  for each row execute function public.award_approved_report_badge();

insert into public.user_achievements (user_id, code)
select distinct user_id, 'approved_report'
from public.practice_reports
where user_id is not null and review_status = 'approved'
on conflict (user_id, code) do nothing;

create or replace function public.set_profile_badge(
  requested_badge_code text,
  requested_selected boolean
)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  current_user_id uuid := (select auth.uid());
  selected_count integer;
begin
  if current_user_id is null then
    raise exception 'AUTHENTICATION_REQUIRED' using errcode = '42501';
  end if;
  if not exists (
    select 1 from public.user_achievements
    where user_id = current_user_id and code = requested_badge_code
  ) then
    raise exception 'BADGE_NOT_EARNED' using errcode = '22023';
  end if;

  -- Serialize concurrent selections for the same account.
  perform 1 from public.profiles where id = current_user_id for update;
  if requested_selected then
    select count(*) into selected_count
    from public.user_profile_badges
    where user_id = current_user_id and selected = true
      and badge_code <> requested_badge_code;
    if selected_count >= 3 then
      raise exception 'BADGE_LIMIT_REACHED' using errcode = '22023';
    end if;
  end if;

  insert into public.user_profile_badges (user_id, badge_code, selected, updated_at)
  values (current_user_id, requested_badge_code, requested_selected, now())
  on conflict (user_id, badge_code) do update
  set selected = excluded.selected, updated_at = now();
  return requested_selected;
end;
$$;

revoke all on function public.set_profile_badge(text, boolean) from public;
grant execute on function public.set_profile_badge(text, boolean) to authenticated;
