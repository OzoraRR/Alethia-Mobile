-- Module completion invariants and point-ledger integrity.
--
-- Three problems are solved here:
--
-- 1. The catalog order is authoritative. `modules.position` is renumbered to a
--    dense 1..N sequence and made unique so "the next module" is unambiguous.
--    1 = courier-sms, 2 = social-engineering, 3 = executable-file.
--
-- 2. Completion is terminal. A completed row can never fall back to
--    in_progress or not_started. Re-opening a finished module is a read-only
--    review, not a status change, so the guard is a hard rejection.
--
-- 3. Points can no longer be credited twice. The ledger key becomes
--    (user_id, source_type, source_id) and every credit flows through
--    award_points(), which inserts the ledger row and moves the profile balance
--    in one transaction. A duplicate source is a no-op, not a second award.
--
-- A completed module per user is already enforced structurally: the primary key
-- is (user_id, module_id), so "one user, one row, one completion per module"
-- cannot be violated by a concurrent write.

-- ---------------------------------------------------------------------------
-- 1. Dense, unique module ordering
-- ---------------------------------------------------------------------------

-- admin_upsert_module is dropped first, on purpose. It writes an arbitrary
-- position, so while it exists a drifted catalog can hold two modules on one
-- slot. Pinning and adding a unique index over a catalog that the RPC can still
-- reorder is a race; removing the writer first makes the ordering provably
-- stable for the rest of the statement. The rationale for dropping it lives in
-- 20260926030000 with the rest of the admin retirement.
drop function if exists public.admin_upsert_module(
  text, text, text, text, text, text, text, text, smallint, smallint, boolean, boolean
);
drop function if exists public.admin_list_modules(text);

-- Renumber by the current (position, id) order so the sequence is dense and
-- deterministic. This is a no-op for a healthy catalog.
with ordered as (
  select
    module.id,
    row_number() over (order by module.position, module.id)::smallint as next_position
  from public.modules as module
)
update public.modules as module
set position = ordered.next_position
from ordered
where module.id = ordered.id
  and module.position is distinct from ordered.next_position;

alter table public.modules
  drop constraint if exists modules_position_check;

alter table public.modules
  add constraint modules_position_check
  check (position between 1 and 999);

create unique index if not exists modules_position_unique
  on public.modules (position);

comment on column public.modules.position is
  'Dense 1..N catalog order. Unlocks are sequential: position 1 is always available, position N requires position N-1 completed.';

-- Pin the shipped order. UPDATE ... FROM (VALUES ...) rather than an upsert:
-- all three ids already exist, and `insert ... on conflict (id) do update` is
-- evaluated as a fresh insert first, so the six NOT NULL catalog columns with no
-- default would be null and the statement would fail before the conflict branch
-- was ever considered.
update public.modules as module
set position = pinned.position
from (values
  ('courier-sms'::text, 1::smallint),
  ('social-engineering'::text, 2::smallint),
  ('executable-file'::text, 3::smallint)
) as pinned(id, position)
where module.id = pinned.id
  and module.position is distinct from pinned.position;

-- ---------------------------------------------------------------------------
-- 2. Completion is terminal
-- ---------------------------------------------------------------------------

create or replace function public.guard_module_progress_terminal_state()
returns trigger
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
begin
  if old.status = 'completed' and new.status is distinct from 'completed' then
    raise exception 'MODULE_ALREADY_COMPLETED' using errcode = '23514';
  end if;

  -- A completion timestamp is written exactly once and never moved backwards.
  if old.completed_at is not null and new.completed_at is distinct from old.completed_at then
    raise exception 'MODULE_COMPLETION_TIMESTAMP_IMMUTABLE' using errcode = '23514';
  end if;

  return new;
end;
$$;

drop trigger if exists user_module_progress_guard_terminal on public.user_module_progress;
create trigger user_module_progress_guard_terminal
  before update on public.user_module_progress
  for each row execute function public.guard_module_progress_terminal_state();

revoke all on function public.guard_module_progress_terminal_state() from public;

comment on function public.guard_module_progress_terminal_state() is
  'Rejects any downgrade of a completed module and freezes completed_at. A finished module is reviewable, never re-runnable.';

-- begin_module_progress already avoided downgrading a completed row. Make that
-- explicit so the intent survives future edits of the RPC.
--
-- SECURITY DEFINER because module_access_state is not executable by end users.
-- The only value that reaches it is auth.uid(), so it cannot be pointed at
-- another account.
create or replace function public.begin_module_progress(requested_module_id text)
returns public.user_module_progress
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  progress_row public.user_module_progress;
begin
  if (select auth.uid()) is null then
    raise exception 'AUTHENTICATION_REQUIRED' using errcode = '42501';
  end if;

  if not exists (
    select 1
    from public.modules as module
    where module.id = requested_module_id
      and module.is_active = true
      and module.is_published = true
      and module.content_key is not null
  ) then
    raise exception 'MODULE_NOT_AVAILABLE' using errcode = '22023';
  end if;

  -- Starting a locked module is refused server-side. The client card is only a
  -- hint; this is the authority.
  if public.module_access_state(
       (select auth.uid()),
       (select module.position from public.modules as module where module.id = requested_module_id),
       'not_started'
     ) = 'locked' then
    raise exception 'MODULE_LOCKED' using errcode = '42501';
  end if;

  insert into public.user_module_progress as progress (
    user_id,
    module_id,
    status,
    progress_percentage,
    started_at,
    updated_at
  )
  values (
    (select auth.uid()),
    requested_module_id,
    'in_progress',
    1,
    now(),
    now()
  )
  on conflict (user_id, module_id) do update
  set updated_at = now()
  returning * into progress_row;

  return progress_row;
end;
$$;

revoke all on function public.begin_module_progress(text) from public;
grant execute on function public.begin_module_progress(text) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. Access state
-- ---------------------------------------------------------------------------

-- Shared by get_module_access, is_module_unlocked, the training grid and the
-- simulation guard so no caller can drift from another.
create or replace function public.module_access_state(
  requested_user_id uuid,
  requested_position smallint,
  requested_status text
)
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select case
    when requested_status = 'completed' then 'completed'
    when requested_status = 'in_progress' then 'in_progress'
    when requested_position is null or requested_position <= 1 then 'available'
    when coalesce(
      (
        select previous_progress.status
        from public.modules as previous
        left join public.user_module_progress as previous_progress
          on previous_progress.module_id = previous.id
         and previous_progress.user_id = requested_user_id
        where previous.is_active = true
          and previous.is_published = true
          and previous.content_key is not null
          and previous.position < requested_position
        order by previous.position desc
        limit 1
      ),
      'not_started'
    ) = 'completed' then 'available'
    else 'locked'
  end;
$$;

revoke all on function public.module_access_state(uuid, smallint, text) from public;

comment on function public.module_access_state(uuid, smallint, text) is
  'Resolves locked | available | in_progress | completed for one module position. Strictly sequential unlock.';

-- ---------------------------------------------------------------------------
-- 4. Point ledger: (user_id, source_type, source_id)
-- ---------------------------------------------------------------------------

alter table public.user_point_ledger
  add column if not exists source_type text,
  add column if not exists source_id text;

-- The previous uniqueness key was (user_id, reference_key), so this backfill
-- cannot collide.
update public.user_point_ledger
set source_type = reference_type,
    source_id = reference_key
where source_type is null or source_id is null;

-- Dropping the reference_key constraint is a widening, not a tightening: two rows
-- that shared a reference_key under different reference_types were previously
-- forbidden and now are allowed. award_points needs exactly that, because the
-- same logical id under two source types is two distinct awards. Within any one
-- source type the new key is strictly more discriminating, and that is what
-- actually prevents double-awarding.
--
-- The consequence to keep in mind: source_id is now the only thing tying a
-- ledger row to whatever produced it, and admin_quest_impact reconstructs it by
-- string concatenation. Keep that format in one place, or the reconciliation
-- silently stops matching.
alter table public.user_point_ledger
  drop constraint if exists user_point_ledger_reference_unique;

alter table public.user_point_ledger
  drop constraint if exists user_point_ledger_source_unique;

alter table public.user_point_ledger
  add constraint user_point_ledger_source_unique unique (user_id, source_type, source_id);

alter table public.user_point_ledger
  alter column source_type set not null,
  alter column source_id set not null;

alter table public.user_point_ledger
  drop constraint if exists user_point_ledger_source_type_check;

alter table public.user_point_ledger
  drop constraint if exists user_point_ledger_source_id_check;

alter table public.user_point_ledger
  add constraint user_point_ledger_source_type_check
  check (char_length(btrim(source_type)) between 1 and 64);

alter table public.user_point_ledger
  add constraint user_point_ledger_source_id_check
  check (char_length(btrim(source_id)) between 1 and 200);

comment on table public.user_point_ledger is
  'Idempotent point award history keyed by (user_id, source_type, source_id). Clients can read their own rows but cannot insert or update them.';

-- Single entry point for crediting points. The ledger insert and the balance
-- update share a transaction, so `on conflict do nothing` returning no row is
-- proof that nothing was credited.
create or replace function public.award_points(
  requested_user_id uuid,
  requested_amount integer,
  requested_reason text,
  requested_source_type text,
  requested_source_id text
)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  credited_id uuid;
  current_points integer;
begin
  if requested_user_id is null then
    raise exception 'AWARD_USER_REQUIRED' using errcode = '22023';
  end if;

  if requested_amount <= 0 then
    select profile.points
    into current_points
    from public.profiles as profile
    where profile.id = requested_user_id;

    return coalesce(current_points, 0);
  end if;

  insert into public.user_point_ledger (
    user_id,
    amount,
    reason,
    reference_type,
    reference_key,
    source_type,
    source_id
  )
  values (
    requested_user_id,
    requested_amount,
    requested_reason,
    requested_source_type,
    requested_source_id,
    requested_source_type,
    requested_source_id
  )
  on conflict (user_id, source_type, source_id) do nothing
  returning id into credited_id;

  if credited_id is null then
    select profile.points
    into current_points
    from public.profiles as profile
    where profile.id = requested_user_id;

    return coalesce(current_points, 0);
  end if;

  perform set_config('alethia.point_award', 'on', true);
  update public.profiles as profile
  set points = profile.points + requested_amount
  where profile.id = requested_user_id;
  perform set_config('alethia.point_award', 'off', true);

  select profile.points
  into current_points
  from public.profiles as profile
  where profile.id = requested_user_id;

  return coalesce(current_points, 0);
end;
$$;

revoke all on function public.award_points(uuid, integer, text, text, text) from public;

comment on function public.award_points(uuid, integer, text, text, text) is
  'Credits points once per (user_id, source_type, source_id). Returns the resulting balance; a repeated source returns it unchanged.';

-- Route the existing claim path through award_points so quest rewards share
-- the same double-award protection as everything else.
create or replace function public.claim_daily_quest(
  requested_quest_id text,
  requested_quest_date date
)
returns table (
  status text,
  reward_points integer,
  total_points integer
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  current_user_id uuid := (select auth.uid());
  quest_row public.user_daily_quests%rowtype;
  awarded_points integer;
  balance_after integer;
  claim_reference text;
begin
  if current_user_id is null then
    raise exception 'AUTHENTICATION_REQUIRED' using errcode = '42501';
  end if;

  select *
  into quest_row
  from public.user_daily_quests
  where user_id = current_user_id
    and quest_date = requested_quest_date
    and quest_id = requested_quest_id
  for update;

  if not found then
    raise exception 'DAILY_QUEST_NOT_FOUND' using errcode = 'P0002';
  end if;

  if quest_row.status = 'claimed' then
    select profile.points
    into balance_after
    from public.profiles as profile
    where profile.id = current_user_id;

    return query select 'claimed'::text, 0, coalesce(balance_after, 0);
    return;
  end if;

  if quest_row.status <> 'completed' then
    raise exception 'DAILY_QUEST_NOT_COMPLETED' using errcode = '23514';
  end if;

  claim_reference := 'daily_quest:' || requested_quest_date::text || ':' || requested_quest_id;
  awarded_points := quest_row.reward_points;

  balance_after := public.award_points(
    current_user_id,
    awarded_points,
    'daily_quest_claim',
    'daily_quest',
    claim_reference
  );

  update public.user_daily_quests
  set status = 'claimed',
      claimed_at = coalesce(claimed_at, now()),
      updated_at = now()
  where user_id = current_user_id
    and quest_date = requested_quest_date
    and quest_id = requested_quest_id;

  return query select 'claimed'::text, awarded_points, balance_after;
end;
$$;

revoke all on function public.claim_daily_quest(text, date) from public;
grant execute on function public.claim_daily_quest(text, date) to authenticated;
