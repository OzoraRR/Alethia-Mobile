-- Daily-quest administration.
--
-- Quest definitions live in daily_quests and each user gets a frozen copy in
-- user_daily_quests on their local date. That split is what makes the admin
-- surface dangerous if it is done carelessly:
--
--   * Editing a quest that is already assigned silently rewrites the meaning of
--     progress some users have already banked.
--   * Reordering positions changes the order every user's panel renders in.
--   * Applying a definition to a date can touch every row in the table.
--
-- So the three new RPCs are: an impact preview, an explicit apply that reports
-- exactly how many users it touched, and a reorder that is validated against the
-- full catalog.
--
-- admin_upsert_quest is not in this file. Making it refuse to move a live quest
-- also required renaming a parameter, which PostgreSQL refuses to do through
-- CREATE OR REPLACE ("cannot change name of input parameter"). 20260926090000
-- owns that function: drop, create, revoke, grant.

-- ---------------------------------------------------------------------------
-- 1. admin_apply_quest_definition
-- ---------------------------------------------------------------------------

create or replace function public.admin_apply_quest_definition(
  requested_token text,
  requested_quest_date date default null,
  requested_dry_run boolean default false
)
returns table (
  quest_date date,
  active_quest_count integer,
  users_processed integer,
  assignments_created integer,
  users_already_assigned integer,
  is_dry_run boolean
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  session_username text;
  profile_row record;
  active_count integer;
  users_total integer;
  already_total integer;
  created_total integer;
  per_user_created integer;
  reported_date date;
begin
  select account.username
  into session_username
  from public.admin_sessions as session
  join public.admin_accounts as account on account.id = session.admin_id
  where session.token_hash = encode(extensions.digest(requested_token, 'sha256'), 'hex')
    and session.expires_at > now()
    and account.is_active = true
  limit 1;

  if session_username is null then
    raise exception 'ADMIN_SESSION_REQUIRED' using errcode = '42501';
  end if;

  select count(*)::integer
  into active_count
  from public.daily_quests as quest
  where quest.is_active = true;

  if active_count = 0 then
    raise exception 'NO_ACTIVE_QUESTS' using errcode = '23514';
  end if;

  users_total := 0;
  already_total := 0;
  created_total := 0;
  reported_date := requested_quest_date;

  for profile_row in
    select profile.id, profile.timezone
    from public.profiles as profile
    -- A total order, not a nicety. created_at alone is not unique:
    -- on_auth_user_created stamps now(), which is transaction time, so a batch
    -- of signups in one transaction ties. Without the id tiebreak the loop picks
    -- a winner by heap order while admin_quest_impact picked a different one,
    -- and the two admin surfaces reported different calendar days.
    order by profile.created_at, profile.id
  loop
    users_total := users_total + 1;

    -- The first profile in that order decides the reported date, so it matches
    -- the rows that were actually written rather than a separate global "today".
    if reported_date is null then
      reported_date := (now() at time zone profile_row.timezone)::date;
    end if;

    if requested_dry_run then
      -- Count what the insert would create, without creating it. The
      -- confirmation the operator reads before committing has to come from the
      -- same rule the insert uses, or it is a guess.
      select count(*)::integer
      into per_user_created
      from public.daily_quests as quest
      where quest.is_active = true
        and not exists (
          select 1
          from public.user_daily_quests as assignment
          where assignment.user_id = profile_row.id
            and assignment.quest_date = coalesce(
              requested_quest_date,
              (now() at time zone profile_row.timezone)::date
            )
            and assignment.quest_id = quest.id
        );

      -- Counts USERS, not assignment rows. A user counts as already assigned
      -- when the apply would create nothing for them, i.e. they already hold
      -- every active quest for the date. The earlier `active_count -
      -- per_user_created` counted (user x quest) pairs, so two fully assigned
      -- users with three active quests reported six, which is not what
      -- "users_already_assigned" says.
      if per_user_created = 0 then
        already_total := already_total + 1;
      end if;
    else
      per_user_created := public.ensure_daily_quests_for_user(
        profile_row.id,
        coalesce(requested_quest_date, (now() at time zone profile_row.timezone)::date)
      );

      -- Inside the loop, not after it. After the loop per_user_created holds
      -- only the last user's value, so a population where some users already
      -- have every active quest and some have none reported zero
      -- already-assigned users on the one path that writes. The dry-run branch
      -- above has always had it in the right place.
      if per_user_created = 0 then
        already_total := already_total + 1;
      end if;
    end if;

    created_total := created_total + per_user_created;
  end loop;

  users_total := coalesce(users_total, 0);
  already_total := coalesce(already_total, 0);
  created_total := coalesce(created_total, 0);

  -- A dry run is a read. It must not leave an audit entry claiming work
  -- happened.
  if not requested_dry_run then
    perform public.write_admin_audit(
      requested_token,
      'quest.apply_definition',
      'daily_quests',
      coalesce(requested_quest_date::text, 'today'),
      jsonb_build_object(
        'users_processed', users_total,
        'assignments_created', created_total,
        'users_already_assigned', already_total,
        'active_quest_count', active_count
      )
    );
  end if;

  -- The date is reported from the first profile in a total order, not from a
  -- global "today". admin_quest_impact resolves its default the same way, so the
  -- preview an operator confirms against and the apply that commits name the
  -- same calendar day.
  --
  -- Known limit: assignments are written per user in each user's own timezone,
  -- so a population spanning far-apart zones has rows on two different dates.
  -- This reports the date of the first profile and, for the rest, the date that
  -- user's own local day resolves to. A single number cannot describe both. It
  -- is deterministic and it is the number the apply acted on, which is what the
  -- confirmation needs; it is not a whole-population total.
  return query
  select
    reported_date,
    active_count,
    users_total,
    created_total,
    already_total,
    requested_dry_run;
end;
$$;

revoke all on function public.admin_apply_quest_definition(text, date, boolean) from public;
grant execute on function public.admin_apply_quest_definition(text, date, boolean) to anon;

comment on function public.admin_apply_quest_definition(text, date, boolean) is
  'Materialises the active quest set for every profile, or reports what it would create when dry_run is true. Returns users processed, rows created and rows already present.';

-- ---------------------------------------------------------------------------
-- 2. admin_reorder_quests
-- ---------------------------------------------------------------------------

create or replace function public.admin_reorder_quests(
  requested_token text,
  requested_ordered_ids text[]
)
returns table (
  quest_id text,
  quest_position smallint
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  catalog_ids text[];
  supplied_ids text[];
  next_position integer;
  ordered_id text;
begin
  if not exists (select 1 from public.admin_session_info(requested_token)) then
    raise exception 'ADMIN_SESSION_REQUIRED' using errcode = '42501';
  end if;

  if requested_ordered_ids is null or array_length(requested_ordered_ids, 1) is null then
    raise exception 'QUEST_ORDER_REQUIRED' using errcode = '22023';
  end if;

  select coalesce(array_agg(quest.id order by quest.id), '{}'::text[])
  into catalog_ids
  from public.daily_quests as quest;

  select coalesce(array_agg(distinct value), '{}'::text[])
  into supplied_ids
  from unnest(requested_ordered_ids) as value;

  if array_length(supplied_ids, 1) is distinct from array_length(catalog_ids, 1) then
    raise exception 'QUEST_ORDER_INCOMPLETE' using errcode = '22023';
  end if;

  if (
    select count(*)
    from (
      select value
      from unnest(supplied_ids) as value
      except
      select value
      from unnest(catalog_ids) as value
    ) as missing
  ) > 0 then
    raise exception 'QUEST_ORDER_UNKNOWN_ID' using errcode = '22023';
  end if;

  next_position := 0;
  foreach ordered_id in array supplied_ids
  loop
    next_position := next_position + 1;
    update public.daily_quests
    set position = next_position
    where id = ordered_id;
  end loop;

  perform public.write_admin_audit(
    requested_token,
    'quest.reorder',
    'daily_quests',
    'catalog',
    jsonb_build_object('order', to_jsonb(supplied_ids))
  );

  return query
  select quest.id, quest.position
  from public.daily_quests as quest
  order by quest.position, quest.id;
end;
$$;

revoke all on function public.admin_reorder_quests(text, text[]) from public;
grant execute on function public.admin_reorder_quests(text, text[]) to anon;

comment on function public.admin_reorder_quests(text, text[]) is
  'Assigns position 1..N from the supplied id array. The array must be a permutation of the whole catalog.';

-- ---------------------------------------------------------------------------
-- 3. admin_quest_impact
-- ---------------------------------------------------------------------------

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

  resolved_date := coalesce(requested_quest_date, (now() at time zone 'UTC')::date);

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

comment on function public.admin_quest_impact(text, text, date) is
  'Per-status assignment counts and points already paid out for one quest on one date. Backs the apply confirmation.';

-- ---------------------------------------------------------------------------
-- 4. admin_upsert_quest
-- ---------------------------------------------------------------------------

-- Removed from this file. The quest_type parameter had to be renamed to
-- requested_quest_type (it is also a column of quest_event_registry, and with
-- the default plpgsql.variable_conflict = error the unprefixed reference in the
-- registry lookup was ambiguous, 42702, so the function raised the moment it was
-- called).
--
-- Renaming an input parameter is NOT a create-or-replace operation. PostgreSQL
-- refuses it outright:
--
--   ERROR: cannot change name of input parameter "quest_type"
--   HINT: Use DROP FUNCTION admin_upsert_quest(...) first.
--
-- An earlier attempt at documenting the fix in place put the renamed signature
-- behind a `create or replace` here. That was not inert, it was fatal: it aborted
-- this whole file, which took admin_apply_quest_definition, admin_reorder_quests
-- and the admin_list_quests registry join down with it.
--
-- 20260926090000 owns the function now: drop, create, revoke, grant.

-- ---------------------------------------------------------------------------
-- 5. admin_list_quests gains the registry join
-- ---------------------------------------------------------------------------

-- The projection gains two columns. CREATE OR REPLACE cannot widen a RETURNS
-- TABLE, so the previous object has to go first.
drop function if exists public.admin_list_quests(text);

create function public.admin_list_quests(requested_token text)
returns table (
  id text, title text, description text, quest_type text,
  target_value smallint, reward_points integer, quest_position smallint, is_active boolean,
  event_key text, is_assigned boolean
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not exists (select 1 from public.admin_session_info(requested_token)) then
    raise exception 'ADMIN_SESSION_REQUIRED' using errcode = '42501';
  end if;

  return query
  select
    quest.id,
    quest.title,
    quest.description,
    quest.quest_type,
    quest.target_value,
    quest.reward_points,
    quest.position as quest_position,
    quest.is_active,
    registry.event_key,
    exists (
      select 1
      from public.user_daily_quests as assignment
      where assignment.quest_id = quest.id
    )
  from public.daily_quests as quest
  left join public.quest_event_registry as registry
    on registry.quest_type = quest.quest_type
  order by quest.position, quest.id;
end;
$$;

revoke all on function public.admin_list_quests(text) from public;
grant execute on function public.admin_list_quests(text) to anon;
