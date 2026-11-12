-- Keep Courier SMS score-gated, make Social Engineering an unscored
-- reconstruction, then unlock Malicious Document from its completed status.
-- This forward migration preserves historical scores and completion dates.

create or replace function public.module_access_state(
  requested_user_id uuid,
  requested_position smallint,
  requested_status text
)
returns text
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  current_module public.modules;
  current_progress public.user_module_progress;
  prior_module record;
  prior_progress public.user_module_progress;
begin
  select * into current_module
  from public.modules
  where position = requested_position
    and is_active
    and is_published
    and content_key is not null
  limit 1;
  if not found then return 'locked'; end if;

  select * into current_progress
  from public.user_module_progress
  where user_id = requested_user_id
    and module_id = current_module.id;

  if current_module.id = 'courier-sms' then
    if current_progress.status = 'completed' and current_progress.verified_score = 100 then
      return 'completed';
    end if;
    return 'available';
  end if;

  for prior_module in
    select id, position
    from public.modules
    where position < requested_position
      and is_active
      and is_published
      and content_key is not null
    order by position
  loop
    select * into prior_progress
    from public.user_module_progress
    where user_id = requested_user_id
      and module_id = prior_module.id;

    if prior_module.id = 'courier-sms' then
      if prior_progress.status is distinct from 'completed'
        or prior_progress.verified_score is distinct from 100 then
        return 'locked';
      end if;
    elsif prior_module.id = 'social-engineering' then
      if prior_progress.status is distinct from 'completed' then
        return 'locked';
      end if;
    elsif prior_progress.status is distinct from 'completed' then
      return 'locked';
    end if;
  end loop;

  if current_progress.status = 'completed' then return 'completed'; end if;
  if current_progress.status = 'in_progress' then return 'in_progress'; end if;
  return 'available';
end;
$$;

create or replace function public.complete_verified_practice_attempt(
  requested_attempt_id uuid,
  requested_decisions jsonb
)
returns table (score smallint, perfect boolean, started_at timestamptz)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  caller_id uuid := (select auth.uid());
  attempt_row public.practice_attempts;
  item text;
  decisions text[] := '{}';
  last_rank integer := 0;
  item_rank integer;
  sender_assessment text;
  link_assessment text;
  verified boolean := false;
  fields integer := 0;
  artifacts integer := 0;
  mitigation text;
  final_choice text;
  reconstruction_finished boolean := false;
  results boolean[];
  computed_score smallint;
  computed_perfect boolean;
  computed_outcome text;
  completed_time timestamptz := clock_timestamp();
  prior public.user_module_progress;
  next_status text;
  next_mastery text;
  next_score smallint;
  next_verified_score smallint;
  next_progress smallint;
  next_completed_at timestamptz;
  event_metadata jsonb;
  previous_guard_setting text := current_setting('alethia.verified_module_completion', true);
begin
  if caller_id is null then
    raise exception 'AUTHENTICATION_REQUIRED' using errcode = '42501';
  end if;
  if requested_decisions is null
    or jsonb_typeof(requested_decisions) <> 'array'
    or jsonb_array_length(requested_decisions) > 12 then
    raise exception 'INVALID_DECISION_SEQUENCE' using errcode = '22023';
  end if;

  select * into attempt_row
  from public.practice_attempts
  where id = requested_attempt_id
    and user_id = caller_id
  for update;
  if not found then raise exception 'ATTEMPT_NOT_FOUND' using errcode = '42501'; end if;
  if attempt_row.completed_at is not null then
    raise exception 'ATTEMPT_ALREADY_COMPLETED' using errcode = '23514';
  end if;

  for item in
    select value from jsonb_array_elements_text(requested_decisions) as decision_item(value)
  loop
    if item = any(decisions) then
      raise exception 'DUPLICATE_DECISION' using errcode = '22023';
    end if;
    decisions := array_append(decisions, item);

    if attempt_row.module_id = 'courier-sms' then
      item_rank := case
        when item in ('assess:sender_unverified','assess:sender_trusted') then 1
        when item in ('assess:link_suspicious','assess:link_trusted') then 2
        when item = 'verify_official_channel' then 3
        when item in ('choose:open_link','choose:verify_official_channel','choose:report_delete') then 4
        else null end;
      if item_rank is null or item_rank < last_rank
        or (item_rank = 1 and sender_assessment is not null)
        or (item_rank = 2 and link_assessment is not null)
        or (item_rank = 4 and final_choice is not null) then
        raise exception 'INVALID_DECISION_SEQUENCE' using errcode = '22023';
      end if;
      if item_rank = 1 then sender_assessment := split_part(item, ':', 2); end if;
      if item_rank = 2 then link_assessment := split_part(item, ':', 2); end if;
      if item_rank = 3 then verified := true; end if;
      if item_rank = 4 then final_choice := split_part(item, ':', 2); end if;
    elsif attempt_row.module_id = 'social-engineering' then
      item_rank := case
        when item in ('artifact:visual','artifact:routine','artifact:complaint','artifact:career','artifact:family') then 1
        when item in ('mitigation:limit','mitigation:separate','mitigation:verify') then 2
        when item = 'complete:reconstruction' then 3
        else null end;
      if item_rank is null or item_rank < last_rank
        -- Any number of distinct artifacts may be submitted before mitigation.
        -- Once the learner leaves extraction, the sequence cannot go backward.
        or (item_rank = 1 and last_rank > 1)
        or (item_rank = 2 and mitigation is not null)
        or (item_rank = 3 and reconstruction_finished) then
        raise exception 'INVALID_DECISION_SEQUENCE' using errcode = '22023';
      end if;
      if item_rank = 1 then artifacts := artifacts + 1; end if;
      if item_rank = 2 then mitigation := split_part(item, ':', 2); end if;
      if item_rank = 3 then reconstruction_finished := true; end if;
    elsif attempt_row.module_id = 'executable-file' then
      item_rank := case
        when item in ('inspect:source','inspect:filename','inspect:extension','inspect:link') then 1
        when item = 'verify_official_channel' then 2
        when item in ('choose:open','choose:verify','choose:ignore','choose:report') then 3
        else null end;
      if item_rank is null or item_rank < last_rank
        or (item_rank = 1 and last_rank > 1)
        or (item_rank = 3 and final_choice is not null) then
        raise exception 'INVALID_DECISION_SEQUENCE' using errcode = '22023';
      end if;
      if item_rank = 1 then fields := fields + 1; end if;
      if item_rank = 2 then verified := true; end if;
      if item_rank = 3 then final_choice := split_part(item, ':', 2); end if;
    else
      raise exception 'MODULE_NOT_AVAILABLE' using errcode = '22023';
    end if;
    last_rank := item_rank;
  end loop;

  if attempt_row.module_id = 'courier-sms' then
    if sender_assessment is null or link_assessment is null or final_choice is null then
      raise exception 'INVALID_DECISION_SEQUENCE' using errcode = '22023';
    end if;
    results := array[
      sender_assessment = 'sender_unverified',
      link_assessment = 'link_suspicious',
      verified,
      final_choice <> 'open_link'
    ];
  elsif attempt_row.module_id = 'social-engineering' then
    if artifacts < 2 or artifacts > 5 or mitigation is null or not reconstruction_finished then
      raise exception 'INVALID_DECISION_SEQUENCE' using errcode = '22023';
    end if;
    -- This lesson has no score. Completion is the end of the guided reconstruction,
    -- regardless of the chosen defensive response.
    computed_outcome := 'completed';
  else
    if fields < 2 or not verified or final_choice is null then
      raise exception 'INVALID_DECISION_SEQUENCE' using errcode = '22023';
    end if;
    results := array[fields >= 2, verified, final_choice <> 'open'];
  end if;

  if attempt_row.module_id <> 'social-engineering' then
    computed_score := round(
      100.0 * (select count(*) from unnest(results) as result(correct) where correct)
      / cardinality(results)
    )::smallint;
    computed_perfect := computed_score = 100;
    computed_outcome := case
      when computed_perfect then 'safe'
      when attempt_row.module_id = 'courier-sms' and final_choice = 'open_link' then 'unsafe'
      when attempt_row.module_id = 'executable-file' and final_choice = 'open' then 'unsafe'
      else 'mixed' end;
  end if;

  perform set_config('alethia.verified_module_completion', 'on', true);
  update public.practice_attempts
  set outcome = computed_outcome, completed_at = completed_time
  where id = attempt_row.id;

  select * into prior
  from public.user_module_progress
  where user_id = caller_id and module_id = attempt_row.module_id
  for update;

  if attempt_row.module_id = 'social-engineering' then
    next_status := 'completed';
    next_mastery := coalesce(prior.mastery_level, 'familiar');
    next_score := prior.score;
    next_verified_score := prior.verified_score;
    next_progress := 100;
    next_completed_at := coalesce(prior.completed_at, completed_time);
    event_metadata := jsonb_build_object(
      'outcome', 'completed',
      'rubric_version', 'social-engineering-reconstruction-v2',
      'artifact_count', artifacts,
      'completed_at', completed_time
    );
  else
    next_status := case when computed_perfect or prior.status = 'completed' then 'completed' else 'in_progress' end;
    next_mastery := case when computed_perfect then 'skilled' else coalesce(prior.mastery_level, 'needs_practice') end;
    next_score := greatest(coalesce(prior.score, 0), computed_score);
    next_verified_score := greatest(coalesce(prior.verified_score, 0), computed_score);
    next_progress := case when computed_perfect or prior.status = 'completed' then 100 else coalesce(prior.progress_percentage, 1) end;
    next_completed_at := case when prior.status = 'completed' then prior.completed_at when computed_perfect then completed_time else null end;
    event_metadata := jsonb_build_object(
      'score', computed_score,
      'perfect', computed_perfect,
      'outcome', computed_outcome,
      'rubric_version', case attempt_row.module_id when 'courier-sms' then 'courier-sms-v2' else 'malicious-document-v1' end,
      'decision_results', to_jsonb(results),
      'completed_at', completed_time
    );
  end if;

  insert into public.user_module_progress as progress (
    user_id,module_id,status,mastery_level,inspect_practised,verify_practised,report_practised,
    last_practised_at,score,verified_score,progress_percentage,started_at,completed_at,updated_at
  ) values (
    caller_id,attempt_row.module_id,next_status,next_mastery,
    coalesce(prior.inspect_practised,false) or
      case when attempt_row.module_id = 'social-engineering' then artifacts >= 2 else results[1] end,
    coalesce(prior.verify_practised,false) or verified,
    coalesce(prior.report_practised,false) or coalesce(final_choice in ('report_delete','report'),false),
    completed_time,next_score,next_verified_score,next_progress,
    coalesce(prior.started_at,attempt_row.started_at),next_completed_at,completed_time
  ) on conflict (user_id,module_id) do update set
    status = case when progress.status = 'completed' or excluded.status = 'completed' then 'completed' else 'in_progress' end,
    mastery_level = case
      when attempt_row.module_id = 'social-engineering' then coalesce(progress.mastery_level, 'familiar')
      when excluded.score = 100 then 'skilled'
      else progress.mastery_level end,
    inspect_practised = progress.inspect_practised or excluded.inspect_practised,
    verify_practised = progress.verify_practised or excluded.verify_practised,
    report_practised = progress.report_practised or excluded.report_practised,
    last_practised_at = completed_time,
    score = coalesce(excluded.score, progress.score),
    verified_score = coalesce(excluded.verified_score, progress.verified_score),
    progress_percentage = case when progress.status = 'completed' or excluded.status = 'completed' then 100 else progress.progress_percentage end,
    started_at = coalesce(progress.started_at,excluded.started_at),
    completed_at = coalesce(progress.completed_at,excluded.completed_at),
    updated_at = completed_time;

  insert into public.practice_events(attempt_id,event_type,stage,metadata_json)
  values (attempt_row.id,'module_completed','complete',event_metadata);
  perform set_config('alethia.verified_module_completion', coalesce(previous_guard_setting, ''), true);
  return query select computed_score,computed_perfect,attempt_row.started_at;
end;
$$;

revoke all on function public.complete_verified_practice_attempt(uuid,jsonb) from public;
grant execute on function public.complete_verified_practice_attempt(uuid,jsonb) to authenticated;
