-- Forward-only server scoring and sequential unlock enforcement.
-- This file is a local candidate only; it has not been applied remotely.

alter table public.user_module_progress add column if not exists verified_score smallint;
alter table public.user_module_progress drop constraint if exists user_module_progress_verified_score_check;
alter table public.user_module_progress add constraint user_module_progress_verified_score_check
  check (verified_score is null or verified_score between 0 and 100);

create or replace function public.module_access_state(requested_user_id uuid, requested_position smallint, requested_status text)
returns text language sql stable security definer set search_path = public, pg_temp as $$
  select case
    when requested_position <= 1 then case when current_progress.verified_score = 100 and requested_status = 'completed' then 'completed' else 'available' end
    when exists (
      select 1 from public.modules as prior_module
      left join public.user_module_progress as prior_progress
        on prior_progress.user_id = requested_user_id and prior_progress.module_id = prior_module.id
      where prior_module.position < requested_position and prior_module.is_active
        and prior_module.is_published and prior_module.content_key is not null
        and not coalesce(prior_progress.status = 'completed' and prior_progress.verified_score = 100, false)
    ) then 'locked'
    when current_progress.verified_score = 100 and requested_status = 'completed' then 'completed'
    when requested_status = 'in_progress' then 'in_progress'
    else 'available'
  end
  from (select 1) as seed
  left join public.user_module_progress as current_progress
    on current_progress.user_id = requested_user_id
   and current_progress.module_id = (select id from public.modules where position = requested_position limit 1);
$$;

create or replace function public.get_verified_module_access()
returns table (module_id text, module_position smallint, access_state text, progress_status text,
  progress_percentage smallint, score smallint, started_at timestamptz, completed_at timestamptz, notified_at timestamptz)
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare resolved_user_id uuid := (select auth.uid());
begin
  return query select module.id, module.position,
    case when resolved_user_id is null then case when module.position = 1 then 'available' else 'locked' end
      else public.module_access_state(resolved_user_id, module.position, coalesce(progress.status, 'not_started')) end,
    coalesce(progress.status, 'not_started'), coalesce(progress.progress_percentage, 0)::smallint,
    progress.verified_score, progress.started_at, progress.completed_at, progress.notified_at
  from public.modules as module
  left join public.user_module_progress as progress on progress.module_id = module.id and progress.user_id = resolved_user_id
  where module.is_active and module.is_published and module.content_key is not null
  order by module.position;
end;
$$;
revoke all on function public.get_verified_module_access() from public;
grant execute on function public.get_verified_module_access() to anon, authenticated;

create or replace function public.is_module_unlocked(requested_module_id text)
returns boolean language plpgsql stable security definer set search_path = public, pg_temp as $$
declare resolved_user_id uuid := (select auth.uid()); resolved_position smallint; resolved_status text;
begin
  select position into resolved_position from public.modules where id = requested_module_id and is_active and is_published and content_key is not null;
  if not found then return false; end if;
  if resolved_user_id is null then return resolved_position = 1; end if;
  select coalesce(progress.status, 'not_started') into resolved_status from public.modules module
    left join public.user_module_progress progress on progress.module_id = module.id and progress.user_id = resolved_user_id
    where module.id = requested_module_id;
  return public.module_access_state(resolved_user_id, resolved_position, coalesce(resolved_status, 'not_started')) <> 'locked';
end;
$$;

create or replace function public.guard_verified_module_progress()
returns trigger language plpgsql security invoker set search_path = public, pg_temp as $$
begin
  if tg_op = 'INSERT' and current_setting('alethia.verified_module_completion', true) is distinct from 'on' then
    if new.status = 'completed' or new.score is not null or new.verified_score is not null
      or new.completed_at is not null or new.progress_percentage = 100 then
      raise exception 'MODULE_COMPLETION_REQUIRES_VERIFIED_ATTEMPT' using errcode = '42501';
    end if;
  elsif current_setting('alethia.verified_module_completion', true) is distinct from 'on'
    and (new.status is distinct from old.status or new.score is distinct from old.score
      or new.progress_percentage is distinct from old.progress_percentage or new.completed_at is distinct from old.completed_at
      or new.mastery_level is distinct from old.mastery_level or new.inspect_practised is distinct from old.inspect_practised
      or new.verify_practised is distinct from old.verify_practised or new.report_practised is distinct from old.report_practised
      or new.verified_score is distinct from old.verified_score) then
    raise exception 'MODULE_COMPLETION_REQUIRES_VERIFIED_ATTEMPT' using errcode = '42501';
  end if;
  return new;
end;
$$;
drop trigger if exists user_module_progress_verified_guard on public.user_module_progress;
create trigger user_module_progress_verified_guard before insert or update on public.user_module_progress
  for each row execute function public.guard_verified_module_progress();
revoke all on function public.guard_verified_module_progress() from public;

create or replace function public.guard_verified_attempt_result()
returns trigger language plpgsql security invoker set search_path = public, pg_temp as $$
begin
  if current_setting('alethia.verified_module_completion', true) is distinct from 'on'
    and (new.outcome is distinct from old.outcome or new.completed_at is distinct from old.completed_at) then
    raise exception 'ATTEMPT_COMPLETION_REQUIRES_VERIFIED_RESULT' using errcode = '42501';
  end if;
  return new;
end;
$$;
drop trigger if exists practice_attempts_verified_guard on public.practice_attempts;
create trigger practice_attempts_verified_guard before update on public.practice_attempts
  for each row execute function public.guard_verified_attempt_result();
revoke all on function public.guard_verified_attempt_result() from public;

create or replace function public.guard_coarse_practice_event()
returns trigger language plpgsql security invoker set search_path = public, pg_temp as $$
begin
  if new.event_type = 'module_completed' and current_setting('alethia.verified_module_completion', true) is distinct from 'on' then
    raise exception 'MODULE_COMPLETION_EVENT_REQUIRES_VERIFIED_RESULT' using errcode = '42501';
  end if;
  if current_setting('alethia.verified_module_completion', true) is distinct from 'on' then
    new.metadata_json := '{}'::jsonb;
  end if;
  return new;
end;
$$;
drop trigger if exists practice_events_coarse_guard on public.practice_events;
create trigger practice_events_coarse_guard before insert on public.practice_events
  for each row execute function public.guard_coarse_practice_event();
revoke all on function public.guard_coarse_practice_event() from public;

revoke insert, update on public.practice_attempts from authenticated;
revoke insert, update on public.user_module_progress from authenticated;
revoke all on function public.begin_module_progress(text) from authenticated;

create or replace function public.begin_verified_practice_attempt(requested_module_id text)
returns uuid language plpgsql security definer set search_path = public, pg_temp as $$
declare new_attempt_id uuid;
begin
  if (select auth.uid()) is null then raise exception 'AUTHENTICATION_REQUIRED' using errcode = '42501'; end if;
  perform public.begin_module_progress(requested_module_id);
  insert into public.practice_attempts (user_id, module_id, variant_id)
  values ((select auth.uid()), requested_module_id, 'primary') returning id into new_attempt_id;
  return new_attempt_id;
end;
$$;
revoke all on function public.begin_verified_practice_attempt(text) from public;
grant execute on function public.begin_verified_practice_attempt(text) to authenticated;

create or replace function public.complete_verified_practice_attempt(requested_attempt_id uuid, requested_decisions jsonb)
returns table (score smallint, perfect boolean, started_at timestamptz)
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  caller_id uuid := (select auth.uid());
  attempt_row public.practice_attempts;
  item text;
  decisions text[] := '{}';
  last_rank integer := 0;
  item_rank integer;
  inspected_sender boolean := false;
  inspected_link boolean := false;
  verified boolean := false;
  artifacts integer := 0;
  fields integer := 0;
  mitigation text;
  checked boolean := false;
  final_choice text;
  results boolean[];
  computed_score smallint;
  computed_perfect boolean;
  computed_outcome text;
  completed_time timestamptz := clock_timestamp();
  prior public.user_module_progress;
  previous_guard_setting text := current_setting('alethia.verified_module_completion', true);
begin
  if caller_id is null then raise exception 'AUTHENTICATION_REQUIRED' using errcode = '42501'; end if;
  if requested_decisions is null or jsonb_typeof(requested_decisions) <> 'array' or jsonb_array_length(requested_decisions) > 12 then
    raise exception 'INVALID_DECISION_SEQUENCE' using errcode = '22023';
  end if;
  select * into attempt_row from public.practice_attempts where id = requested_attempt_id and user_id = caller_id for update;
  if not found then raise exception 'ATTEMPT_NOT_FOUND' using errcode = '42501'; end if;
  if attempt_row.completed_at is not null then raise exception 'ATTEMPT_ALREADY_COMPLETED' using errcode = '23514'; end if;

  for item in select value from jsonb_array_elements_text(requested_decisions) as decision_item(value) loop
    if item = any(decisions) then raise exception 'DUPLICATE_DECISION' using errcode = '22023'; end if;
    decisions := array_append(decisions, item);
    if attempt_row.module_id = 'courier-sms' then
      item_rank := case item when 'inspect_sender' then 1 when 'inspect_link' then 2 when 'verify_official_channel' then 3
        when 'choose:open_link' then 4 when 'choose:verify_official_channel' then 4 when 'choose:report_delete' then 4 else null end;
      if item_rank is null or item_rank < last_rank or (item_rank = 4 and final_choice is not null) then
        raise exception 'INVALID_DECISION_SEQUENCE' using errcode = '22023';
      end if;
      if item_rank = 4 then final_choice := split_part(item, ':', 2); end if;
      inspected_sender := inspected_sender or item = 'inspect_sender';
      inspected_link := inspected_link or item = 'inspect_link';
      verified := verified or item = 'verify_official_channel';
    elsif attempt_row.module_id = 'social-engineering' then
      item_rank := case when item in ('artifact:profile','artifact:routine','artifact:handle','artifact:contact','artifact:interest') then 1
        when item in ('mitigation:limit','mitigation:separate','mitigation:verify') then 2
        when item = 'check_official_channel' then 3 else null end;
      if item_rank is null or item_rank < last_rank or (item_rank = 1 and last_rank > 0) then
        raise exception 'INVALID_DECISION_SEQUENCE' using errcode = '22023';
      end if;
      if item_rank = 1 then artifacts := artifacts + 1; end if;
      if item_rank = 2 then
        if mitigation is not null then raise exception 'INVALID_DECISION_SEQUENCE' using errcode = '22023'; end if;
        mitigation := split_part(item, ':', 2);
      end if;
      checked := checked or item = 'check_official_channel';
    elsif attempt_row.module_id = 'executable-file' then
      item_rank := case when item in ('inspect:source','inspect:filename','inspect:extension','inspect:link') then 1
        when item = 'verify_official_channel' then 2
        when item in ('choose:open','choose:verify','choose:ignore','choose:report') then 3 else null end;
      if item_rank is null or item_rank < last_rank or (item_rank = 3 and final_choice is not null) then
        raise exception 'INVALID_DECISION_SEQUENCE' using errcode = '22023';
      end if;
      if item_rank = 1 then fields := fields + 1; end if;
      if item_rank = 3 then final_choice := split_part(item, ':', 2); end if;
      verified := verified or item = 'verify_official_channel';
    else
      raise exception 'MODULE_NOT_AVAILABLE' using errcode = '22023';
    end if;
    last_rank := item_rank;
  end loop;

  if attempt_row.module_id = 'courier-sms' then
    if final_choice is null then raise exception 'INVALID_DECISION_SEQUENCE' using errcode = '22023'; end if;
    results := array[inspected_sender, inspected_link, verified, final_choice <> 'open_link'];
  elsif attempt_row.module_id = 'social-engineering' then
    if artifacts < 2 or mitigation is null or not checked then raise exception 'INVALID_DECISION_SEQUENCE' using errcode = '22023'; end if;
    results := array[artifacts >= 2, mitigation = 'verify', checked];
  else
    if fields < 2 or not verified or final_choice is null then raise exception 'INVALID_DECISION_SEQUENCE' using errcode = '22023'; end if;
    results := array[fields >= 2, verified, final_choice <> 'open'];
  end if;

  computed_score := round(100.0 * (select count(*) from unnest(results) as result(correct) where correct) / cardinality(results))::smallint;
  computed_perfect := computed_score = 100;
  computed_outcome := case when attempt_row.module_id = 'courier-sms' and final_choice = 'open_link' then 'unsafe'
    when attempt_row.module_id = 'courier-sms' then 'safe' when computed_perfect then 'safe' else 'unsafe' end;

  perform set_config('alethia.verified_module_completion', 'on', true);
  update public.practice_attempts set outcome = computed_outcome, completed_at = completed_time where id = attempt_row.id;
  select * into prior from public.user_module_progress where user_id = caller_id and module_id = attempt_row.module_id for update;
  insert into public.user_module_progress as progress (
    user_id,module_id,status,mastery_level,inspect_practised,verify_practised,report_practised,
    last_practised_at,score,verified_score,progress_percentage,started_at,completed_at,updated_at
  ) values (
    caller_id,attempt_row.module_id,
    case when computed_perfect or prior.status = 'completed' then 'completed' else 'in_progress' end,
    case when computed_perfect then 'skilled' else coalesce(prior.mastery_level,'needs_practice') end,
    coalesce(prior.inspect_practised,false) or results[1],
    coalesce(prior.verify_practised,false) or verified,
    coalesce(prior.report_practised,false) or coalesce(final_choice in ('report_delete','report'),false) or coalesce(mitigation = 'separate',false),
    completed_time,greatest(coalesce(prior.score,0),computed_score),greatest(coalesce(prior.verified_score,0),computed_score),
    case when computed_perfect or prior.status = 'completed' then 100 else coalesce(prior.progress_percentage,1) end,
    coalesce(prior.started_at,attempt_row.started_at),
    case when prior.status = 'completed' then prior.completed_at when computed_perfect then completed_time else null end,
    completed_time
  ) on conflict (user_id,module_id) do update set
    status = case when progress.status = 'completed' or excluded.status = 'completed' then 'completed' else 'in_progress' end,
    mastery_level = case when excluded.score = 100 then 'skilled' else progress.mastery_level end,
    inspect_practised = progress.inspect_practised or excluded.inspect_practised,
    verify_practised = progress.verify_practised or excluded.verify_practised,
    report_practised = progress.report_practised or excluded.report_practised,
    last_practised_at = completed_time,
    score = greatest(coalesce(progress.score,0),excluded.score),
    verified_score = greatest(coalesce(progress.verified_score,0),excluded.verified_score),
    progress_percentage = case when progress.status = 'completed' or excluded.status = 'completed' then 100 else progress.progress_percentage end,
    started_at = coalesce(progress.started_at,excluded.started_at),
    completed_at = case when progress.status = 'completed' then progress.completed_at when excluded.status = 'completed' then completed_time else progress.completed_at end,
    updated_at = completed_time;

  insert into public.practice_events(attempt_id,event_type,stage,metadata_json)
  values (attempt_row.id,'module_completed','complete',jsonb_build_object(
    'score',computed_score,'perfect',computed_perfect,'outcome',computed_outcome,
    'rubric_version',case attempt_row.module_id when 'courier-sms' then 'courier-sms-v1' when 'social-engineering' then 'social-engineering-v1' else 'malicious-document-v1' end,
    'decision_results',to_jsonb(results),'completed_at',completed_time));
  perform set_config('alethia.verified_module_completion', coalesce(previous_guard_setting, ''), true);
  return query select computed_score,computed_perfect,attempt_row.started_at;
end;
$$;
revoke all on function public.complete_verified_practice_attempt(uuid,jsonb) from public;
grant execute on function public.complete_verified_practice_attempt(uuid,jsonb) to authenticated;
