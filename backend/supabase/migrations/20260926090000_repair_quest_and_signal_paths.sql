-- Repairs for two write paths that could never succeed.
--
-- Both are pre-existing rather than introduced by the module-completion work,
-- and both were found only by executing the chain and calling the functions.
--
--   1. sync_report_signal_score could not move signal_score. It is SECURITY
--      DEFINER, so current_user is the table owner, but the guard trigger it
--      trips reads auth.role(), which is a session GUC and still reports
--      'authenticated' for the caller's session. The inner UPDATE was therefore
--      always rejected by the outer table's own protection, and report_signals
--      had INSERT and DELETE policies that no client could use.
--
--   2. admin_upsert_quest could not compile its body. quest_type was both a
--      PL/pgSQL parameter and a column of quest_event_registry, and with the
--      default plpgsql.variable_conflict = error that is an ambiguous
--      reference. Renaming the parameter changes the signature, so the old
--      object has to be dropped rather than replaced.
--
-- Also fixed here: guard_module_completion_quest_progress advanced a hardcoded
-- quest id, so it could only ever credit one quest regardless of how many
-- shared that quest_type.

-- ---------------------------------------------------------------------------
-- 1. report_signals -> signal_score
-- ---------------------------------------------------------------------------

create or replace function public.sync_report_signal_score()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  affected_report_id uuid;
begin
  if tg_op = 'DELETE' then
    affected_report_id := old.report_id;
  else
    affected_report_id := new.report_id;
  end if;

  -- signal_score is a cache, so the client is not allowed to set it. This
  -- function is, which means it has to clear the guard the same way
  -- apply_report_review does. Without this the UPDATE below raises
  -- PRACTICE_REPORT_SYSTEM_FIELDS_IMMUTABLE and the cache never moves.
  perform set_config('alethia.admin_action', 'on', true);
  update public.practice_reports
  set signal_score = (
    select count(*)::integer
    from public.report_signals
    where report_id = affected_report_id
  )
  where id = affected_report_id;
  perform set_config('alethia.admin_action', 'off', true);

  return null;
end;
$$;

drop trigger if exists report_signals_sync_score_insert on public.report_signals;
create trigger report_signals_sync_score_insert
  after insert on public.report_signals
  for each row execute function public.sync_report_signal_score();

drop trigger if exists report_signals_sync_score_delete on public.report_signals;
create trigger report_signals_sync_score_delete
  after delete on public.report_signals
  for each row execute function public.sync_report_signal_score();

revoke all on function public.sync_report_signal_score() from public;

-- ---------------------------------------------------------------------------
-- 2. admin_upsert_quest
-- ---------------------------------------------------------------------------

-- Parameter renamed from quest_type to requested_quest_type. Same arity, but
-- PL/pgSQL does not track parameter names, so CREATE OR REPLACE would silently
-- keep the old body and the new name would never take effect. A drop is
-- required for a real change here.
drop function if exists public.admin_upsert_quest(
  text, text, text, text, text, smallint, integer, smallint, boolean
);

create function public.admin_upsert_quest(
  requested_token text,
  quest_id text,
  quest_title text,
  quest_description text,
  requested_quest_type text,
  target_value smallint,
  reward_points integer,
  quest_position smallint,
  quest_is_active boolean
)
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  resolved_id text := btrim(quest_id);
  existing_quest_type text;
  quest_is_live boolean;
  already_exists boolean;
begin
  if not exists (select 1 from public.admin_session_info(requested_token)) then
    raise exception 'ADMIN_SESSION_REQUIRED' using errcode = '42501';
  end if;

  if resolved_id = '' then
    raise exception 'QUEST_ID_REQUIRED' using errcode = '22023';
  end if;

  if reward_points < 0 or reward_points > 10000 then
    raise exception 'QUEST_REWARD_OUT_OF_RANGE' using errcode = '22023';
  end if;

  if target_value < 1 or target_value > 1000 then
    raise exception 'QUEST_TARGET_OUT_OF_RANGE' using errcode = '22023';
  end if;

  if not exists (
    select 1
    from public.quest_event_registry as registry
    where registry.quest_type = requested_quest_type
      and registry.is_supported = true
  ) then
    raise exception 'QUEST_TYPE_NOT_REGISTERED' using errcode = '23503';
  end if;

  select quest.quest_type
  into existing_quest_type
  from public.daily_quests as quest
  where quest.id = resolved_id;

  -- FOUND is not usable here: the exists() query below resets it.
  already_exists := existing_quest_type is not null;

  if already_exists then
    -- A quest is live as soon as one user holds an assignment for it. Changing
    -- the event it listens to at that point would silently re-interpret
    -- progress those users have already banked, so it is refused outright.
    select exists (
      select 1
      from public.user_daily_quests as assignment
      where assignment.quest_id = resolved_id
    )
    into quest_is_live;

    if quest_is_live and existing_quest_type is distinct from requested_quest_type then
      raise exception 'QUEST_TYPE_LOCKED_WHILE_ASSIGNED' using errcode = '23514';
    end if;
  end if;

  insert into public.daily_quests as quest (
    id,
    title,
    description,
    quest_type,
    target_value,
    reward_points,
    position,
    is_active
  )
  values (
    resolved_id,
    btrim(quest_title),
    btrim(quest_description),
    requested_quest_type,
    target_value,
    reward_points,
    coalesce(quest_position, 0),
    coalesce(quest_is_active, true)
  )
  on conflict (id) do update
  set title = excluded.title,
      description = excluded.description,
      quest_type = excluded.quest_type,
      target_value = excluded.target_value,
      reward_points = excluded.reward_points,
      position = excluded.position,
      is_active = excluded.is_active,
      updated_at = now();

  perform public.write_admin_audit(
    requested_token,
    case when already_exists then 'quest.update' else 'quest.create' end,
    'daily_quests',
    resolved_id,
    jsonb_build_object(
      'quest_type', requested_quest_type,
      'target_value', target_value,
      'reward_points', reward_points,
      'position', quest_position,
      'is_active', coalesce(quest_is_active, true)
    )
  );

  return resolved_id;
end;
$$;

revoke all on function public.admin_upsert_quest(
  text, text, text, text, text, smallint, integer, smallint, boolean
) from public;
grant execute on function public.admin_upsert_quest(
  text, text, text, text, text, smallint, integer, smallint, boolean
) to anon;

comment on function public.admin_upsert_quest(text, text, text, text, text, smallint, integer, smallint, boolean) is
  'Creates or updates a quest definition. requested_quest_type is immutable once any user holds an assignment for the quest.';

-- ---------------------------------------------------------------------------
-- 3. Module completion credits every quest of that type, not one hardcoded id
-- ---------------------------------------------------------------------------

-- advance_daily_quest takes a quest_id, not a quest_type, so a module
-- completion has to resolve which quests to credit. Doing that here rather than
-- inside advance_daily_quest keeps that function's contract unchanged for its
-- other caller (the report path).
create or replace function public.advance_module_quests(requested_user_id uuid)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  quest_row record;
  advanced integer := 0;
begin
  if requested_user_id is null then
    return 0;
  end if;

  for quest_row in
    select quest.id
    from public.daily_quests as quest
    where quest.quest_type = 'complete_module'
      and quest.is_active = true
    order by quest.position, quest.id
  loop
    perform public.advance_daily_quest(requested_user_id, quest_row.id, 1);
    advanced := advanced + 1;
  end loop;

  return advanced;
end;
$$;

revoke all on function public.advance_module_quests(uuid) from public;

comment on function public.advance_module_quests(uuid) is
  'Advances every active complete_module quest for one user. Called once per first module completion.';

create or replace function public.guard_module_completion_quest_progress()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.status is distinct from 'completed' then
    return null;
  end if;

  -- Only a transition counts. A replay of a finished module does not move any
  -- counter, which is what makes repeat practice safe.
  if tg_op = 'UPDATE' and old.status = 'completed' then
    return null;
  end if;

  -- advance_daily_quest already skips an assignment that is completed or
  -- claimed, and a quest with target_value > 1 is legitimately still in
  -- progress after one module. The previous version short-circuited on the
  -- first completed quest it found, which meant a second complete_module quest
  -- could never be credited at all.
  perform public.advance_module_quests(new.user_id);

  return null;
end;
$$;

drop trigger if exists user_module_progress_guard_quest_progress on public.user_module_progress;
create trigger user_module_progress_guard_quest_progress
  after insert or update of status on public.user_module_progress
  for each row execute function public.guard_module_completion_quest_progress();

revoke all on function public.guard_module_completion_quest_progress() from public;

-- ---------------------------------------------------------------------------
-- 4. The client writes the renamed parameter
-- ---------------------------------------------------------------------------

comment on function public.admin_list_quests(text) is
  'Quest catalog with the registry event key and whether the quest is already assigned to any user.';

-- admin_quest_impact defaulted to a UTC date while every other function in the
-- schema derives the local day from profiles.timezone, so the preview read a
-- different calendar day than the assignments it was summarising.
create or replace function public.admin_quest_impact(
  requested_token text,
  requested_quest_id text,
  requested_quest_date date default null
)
returns table (
  quest_id text,
  quest_date date,
  quest_title text,
  quest_type text,
  target_value integer,
  reward_points integer,
  assigned_count integer,
  not_started_count integer,
  in_progress_count integer,
  completed_count integer,
  claimed_count integer,
  points_paid_out integer
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  quest_row public.daily_quests%rowtype;
  resolved_date date;
  assigned_count integer;
  not_started_count integer;
  in_progress_count integer;
  completed_count integer;
  claimed_count integer;
  paid_out integer;
begin
  if not exists (select 1 from public.admin_session_info(requested_token)) then
    raise exception 'ADMIN_SESSION_REQUIRED' using errcode = '42501';
  end if;

  select *
  into quest_row
  from public.daily_quests as quest
  where quest.id = requested_quest_id;

  if not found then
    raise exception 'DAILY_QUEST_NOT_FOUND' using errcode = 'P0002';
  end if;

  -- UTC only as a last resort, and only when there are no profiles to ask.
  -- The row selection must match admin_apply_quest_definition exactly, or the
  -- preview reads a different calendar day than the assignments it is
  -- summarising. created_at alone is not a total order: on_auth_user_created
  -- stamps now(), which is transaction time, so a batch of signups in one
  -- transaction ties. The id tiebreak is what makes this deterministic, and it
  -- is the same tiebreak that function's loop uses.
  resolved_date := coalesce(
    requested_quest_date,
    (
      select (now() at time zone profile.timezone)::date
      from public.profiles as profile
      order by profile.created_at, profile.id
      limit 1
    ),
    (now() at time zone 'UTC')::date
  );

  select
    count(*),
    count(*) filter (where assignment.status = 'not_started'),
    count(*) filter (where assignment.status = 'in_progress'),
    count(*) filter (where assignment.status = 'completed'),
    count(*) filter (where assignment.status = 'claimed')
  into
    assigned_count,
    not_started_count,
    in_progress_count,
    completed_count,
    claimed_count
  from public.user_daily_quests as assignment
  where assignment.quest_id = quest_row.id
    and assignment.quest_date = resolved_date;

  select coalesce(sum(ledger.amount), 0)::integer
  into paid_out
  from public.user_point_ledger as ledger
  where ledger.source_type = 'daily_quest'
    and ledger.source_id = 'daily_quest:' || resolved_date::text || ':' || quest_row.id;

  return query
  select
    quest_row.id,
    resolved_date,
    quest_row.title,
    quest_row.quest_type,
    quest_row.target_value::integer,
    quest_row.reward_points,
    assigned_count,
    not_started_count,
    in_progress_count,
    completed_count,
    claimed_count,
    paid_out;
end;
$$;

revoke all on function public.admin_quest_impact(text, text, date) from public;
grant execute on function public.admin_quest_impact(text, text, date) to anon;
