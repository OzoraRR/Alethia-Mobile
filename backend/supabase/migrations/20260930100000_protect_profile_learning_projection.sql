-- Keep the denormalized learning summary derived from protected module progress.
-- Client-owned profile rows remain editable for identity/preferences, but these
-- two projection fields must not be caller-controlled.

create or replace function public.protect_profile_learning_projection()
returns trigger
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
begin
  if current_user in ('anon', 'authenticated') then
    if tg_op = 'INSERT' then
      if new.modules_completed is distinct from 0
         or new.mastery is distinct from 'not_started' then
        raise exception 'PROFILE_LEARNING_PROJECTION_IMMUTABLE'
          using errcode = '42501';
      end if;
    elsif new.modules_completed is distinct from old.modules_completed
       or new.mastery is distinct from old.mastery then
      raise exception 'PROFILE_LEARNING_PROJECTION_IMMUTABLE'
        using errcode = '42501';
    end if;
  end if;

  return new;
end;
$$;

drop trigger if exists profiles_protect_learning_projection on public.profiles;
create trigger profiles_protect_learning_projection
  before insert or update of modules_completed, mastery on public.profiles
  for each row execute function public.protect_profile_learning_projection();

revoke all on function public.protect_profile_learning_projection()
  from public, anon, authenticated, service_role;

comment on function public.protect_profile_learning_projection() is
  'Rejects direct application-role writes to learning summary projections; trusted database functions maintain them from module progress.';

-- Keep both profile projections accurate when protected module progress changes.
create or replace function public.refresh_profile_module_count()
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
  set modules_completed = (
        select count(*)::integer
        from public.user_module_progress as progress
        join public.modules as module on module.id = progress.module_id
        where progress.user_id = affected_user_id
          and progress.status = 'completed'
          and module.is_active = true
          and module.is_published = true
          and module.content_key is not null
      ),
      mastery = coalesce(
        (
          select progress.mastery_level
          from public.user_module_progress as progress
          join public.modules as module on module.id = progress.module_id
          where progress.user_id = affected_user_id
            and progress.status = 'completed'
            and module.is_active = true
            and module.is_published = true
            and module.content_key is not null
          order by case progress.mastery_level
            when 'skilled' then 1
            when 'needs_practice' then 2
            when 'familiar' then 3
            else 4
          end
          limit 1
        ),
        'not_started'
      )
  where profile.id = affected_user_id;

  return null;
end;
$$;

drop trigger if exists user_module_progress_refresh_profile_count on public.user_module_progress;
create trigger user_module_progress_refresh_profile_count
  after insert or update of status, mastery_level or delete on public.user_module_progress
  for each row execute function public.refresh_profile_module_count();

revoke all on function public.refresh_profile_module_count() from public;

create or replace function public.refresh_all_profile_module_counts()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  update public.profiles as profile
  set modules_completed = (
        select count(*)::integer
        from public.user_module_progress as progress
        join public.modules as module on module.id = progress.module_id
        where progress.user_id = profile.id
          and progress.status = 'completed'
          and module.is_active = true
          and module.is_published = true
          and module.content_key is not null
      ),
      mastery = coalesce(
        (
          select progress.mastery_level
          from public.user_module_progress as progress
          join public.modules as module on module.id = progress.module_id
          where progress.user_id = profile.id
            and progress.status = 'completed'
            and module.is_active = true
            and module.is_published = true
            and module.content_key is not null
          order by case progress.mastery_level
            when 'skilled' then 1
            when 'needs_practice' then 2
            when 'familiar' then 3
            else 4
          end
          limit 1
        ),
        'not_started'
      );

  return new;
end;
$$;

drop trigger if exists modules_refresh_profile_counts on public.modules;
create trigger modules_refresh_profile_counts
  after update of is_active, is_published, content_key on public.modules
  for each row execute function public.refresh_all_profile_module_counts();

revoke all on function public.refresh_all_profile_module_counts() from public;

-- Repair projections that may have been written directly before this guard.
update public.profiles as profile
set modules_completed = (
      select count(*)::integer
      from public.user_module_progress as progress
      join public.modules as module on module.id = progress.module_id
      where progress.user_id = profile.id
        and progress.status = 'completed'
        and module.is_active = true
        and module.is_published = true
        and module.content_key is not null
    ),
    mastery = coalesce(
      (
        select progress.mastery_level
        from public.user_module_progress as progress
        join public.modules as module on module.id = progress.module_id
        where progress.user_id = profile.id
          and progress.status = 'completed'
          and module.is_active = true
          and module.is_published = true
          and module.content_key is not null
        order by case progress.mastery_level
          when 'skilled' then 1
          when 'needs_practice' then 2
          when 'familiar' then 3
          else 4
        end
        limit 1
      ),
      'not_started'
    );

-- The verdict gate must consult protected source rows, never a profile cache.
create or replace function public.cast_report_verdict(
  requested_report_id uuid,
  requested_verdict text,
  requested_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  current_user_id uuid := (select auth.uid());
  completed_count integer;
  clean_reason text := nullif(btrim(coalesce(requested_reason, '')), '');
  valid_count integer;
  invalid_count integer;
begin
  if current_user_id is null then
    raise exception 'AUTHENTICATION_REQUIRED' using errcode = '42501';
  end if;
  if requested_verdict is null
    or (requested_verdict <> 'valid' and requested_verdict <> 'invalid')
  then
    raise exception 'INVALID_VERDICT' using errcode = '22023';
  end if;
  if clean_reason is null or char_length(clean_reason) not between 4 and 2000 then
    raise exception 'VERDICT_REASON_REQUIRED' using errcode = '22023';
  end if;

  select count(*)::integer
  into completed_count
  from public.user_module_progress as progress
  join public.modules as module on module.id = progress.module_id
  where progress.user_id = current_user_id
    and progress.status = 'completed'
    and module.is_active = true
    and module.is_published = true
    and module.content_key is not null;

  if completed_count < 2 then
    raise exception 'INVESTIGATOR_REQUIRED' using errcode = '42501';
  end if;
  if not exists (
    select 1 from public.practice_reports
    where practice_reports.id = requested_report_id
  ) then
    raise exception 'REPORT_NOT_FOUND' using errcode = '22023';
  end if;

  insert into public.report_verdicts as vote (report_id, user_id, verdict, reason, updated_at)
  values (requested_report_id, current_user_id, requested_verdict, clean_reason, now())
  on conflict (report_id, user_id) do update
  set verdict = excluded.verdict,
      reason = excluded.reason,
      updated_at = now();

  update public.report_verdicts as vote
  set author_username = profile.username
  from public.profiles as profile
  where vote.report_id = requested_report_id
    and vote.user_id = current_user_id
    and profile.id = current_user_id;

  update public.practice_reports as report
  set investigator_verdict = requested_verdict,
      verdict_by = current_user_id,
      verdict_at = now(),
      updated_at = now()
  where report.id = requested_report_id;

  select
    count(*) filter (where vote.verdict = 'valid'),
    count(*) filter (where vote.verdict = 'invalid')
  into valid_count, invalid_count
  from public.report_verdicts as vote
  where vote.report_id = requested_report_id;

  return jsonb_build_object('valid', valid_count, 'invalid', invalid_count);
end;
$$;

revoke all on function public.cast_report_verdict(uuid, text, text) from public, anon, service_role;
grant execute on function public.cast_report_verdict(uuid, text, text) to authenticated;

comment on function public.cast_report_verdict(uuid, text, text) is
  'Records one reason-bearing investigator vote; eligibility is counted from protected completed module progress, not the editable profile projection.';
