-- Supabase's default function privileges may grant EXECUTE directly to
-- application roles; REVOKE FROM PUBLIC alone does not remove those grants.
-- These routines are internal or are intentionally authenticated-only.

-- Correct the server rubric without rewriting the already-numbered scoring
-- migration. Social Engineering requires two distinct artifact decisions at
-- the same stage, and its official-channel check is also the verification
-- habit recorded in module progress.
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
      if item_rank is null or item_rank < last_rank then
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
    coalesce(prior.verify_practised,false) or verified or checked,
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

revoke all on function public.module_access_state(uuid, smallint, text)
  from public, anon, authenticated, service_role;

revoke all on function public.begin_verified_practice_attempt(text)
  from public, anon, service_role;
grant execute on function public.begin_verified_practice_attempt(text)
  to authenticated;

revoke all on function public.complete_verified_practice_attempt(uuid, jsonb)
  from public, anon, service_role;
grant execute on function public.complete_verified_practice_attempt(uuid, jsonb)
  to authenticated;

-- Password-changing routines are for the database owner/operator only.
revoke all on function public.admin_set_password(text)
  from public, anon, authenticated, service_role;
revoke all on function public.admin_bootstrap_password()
  from public, anon, authenticated, service_role;

-- Report verdicts are user-attributed investigator actions, never anonymous
-- or service-role RPC calls.
revoke all on function public.cast_report_verdict(uuid, text, text)
  from public, anon, service_role;
grant execute on function public.cast_report_verdict(uuid, text, text)
  to authenticated;
