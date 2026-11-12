-- Module read and guard RPCs.
--
-- The client previously derived module state from a localStorage snapshot that
-- it merged against a single flat query. Four separate questions had no
-- database answer, so each was re-implemented (differently) wherever it was
-- needed:
--
--   get_module_access      one row per catalog module with the four-state status
--   is_module_unlocked     the single question the simulation page asks
--   get_module_result      score, analysis and the report behind a completion
--   is_module_rewardable   whether this completion can still pay out
--
-- Plus the two guards the checklist calls for: quest progress is skipped when
-- a module was already completed, and repeating a module never advances the
-- practice streak.

-- ---------------------------------------------------------------------------
-- 1. get_module_access
-- ---------------------------------------------------------------------------

-- Every RPC below resolves the caller from auth.uid() and takes no user id
-- parameter. Accepting one would let any authenticated caller read another
-- account's module progress, which is a smaller leak than it looks: the module
-- ids, statuses and timestamps of an arbitrary user id are guessable and the
-- function would answer for them.
create or replace function public.get_module_access()
returns table (
  module_id text,
  module_position smallint,
  access_state text,
  progress_status text,
  progress_percentage smallint,
  score smallint,
  started_at timestamptz,
  completed_at timestamptz,
  notified_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  resolved_user_id uuid := (select auth.uid());
begin
  return query
  select
    module.id,
    module.position,
    case
      -- With no session there is no server-side progress to reason about. The
      -- offline practice mode keeps working; the authenticated path is strict.
      when resolved_user_id is null then 'available'
      else public.module_access_state(
        resolved_user_id,
        module.position,
        coalesce(progress.status, 'not_started')
      )
    end,
    coalesce(progress.status, 'not_started'),
    -- Cast explicitly. coalesce(smallint, integer) resolves to integer, which
    -- does not match the smallint RETURNS TABLE column and fails with
    -- "structure of query does not match function result type".
    coalesce(progress.progress_percentage, 0)::smallint,
    progress.score,
    progress.started_at,
    progress.completed_at,
    progress.notified_at
  from public.modules as module
  left join public.user_module_progress as progress
    on progress.module_id = module.id
   and progress.user_id = resolved_user_id
  where module.is_active = true
    and module.is_published = true
    and module.content_key is not null
  order by module.position;
end;
$$;

revoke all on function public.get_module_access() from public;
grant execute on function public.get_module_access() to anon, authenticated;

comment on function public.get_module_access() is
  'One row per published module with access_state in (locked, available, in_progress, completed). Order is modules.position.';

-- ---------------------------------------------------------------------------
-- 2. is_module_unlocked
-- ---------------------------------------------------------------------------

create or replace function public.is_module_unlocked(requested_module_id text)
returns boolean
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  resolved_user_id uuid := (select auth.uid());
  resolved_position smallint;
  resolved_status text;
  resolved_state text;
begin
  if requested_module_id is null then
    return false;
  end if;

  select module.position
  into resolved_position
  from public.modules as module
  where module.id = requested_module_id
    and module.is_active = true
    and module.is_published = true
    and module.content_key is not null;

  if not found then
    return false;
  end if;

  if resolved_user_id is null then
    return true;
  end if;

  select coalesce(progress.status, 'not_started')
  into resolved_status
  from public.modules as module
  left join public.user_module_progress as progress
    on progress.module_id = module.id
   and progress.user_id = resolved_user_id
  where module.id = requested_module_id;

  resolved_state := public.module_access_state(
    resolved_user_id,
    resolved_position,
    coalesce(resolved_status, 'not_started')
  );

  return resolved_state <> 'locked';
end;
$$;

revoke all on function public.is_module_unlocked(text) from public;
grant execute on function public.is_module_unlocked(text) to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 3. is_module_rewardable
-- ---------------------------------------------------------------------------

-- Has this completion been fully processed?
--
-- The predicate is notified_at, not the point ledger. Completion is terminal and
-- the completion path awards achievements and writes the notification in the
-- same transaction, so there is no separate "claim" step for a module: what can
-- still be outstanding is the delivery. An earlier version of this function
-- keyed on a user_point_ledger row with source_type = 'module', which nothing
-- in the system writes, so it returned true for every completed module forever.
create or replace function public.is_module_rewardable(requested_module_id text)
returns boolean
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  resolved_user_id uuid := (select auth.uid());
  rewardable boolean;
begin
  if resolved_user_id is null or requested_module_id is null then
    return false;
  end if;

  select exists (
    select 1
    from public.user_module_progress as progress
    where progress.user_id = resolved_user_id
      and progress.module_id = requested_module_id
      and progress.status = 'completed'
      and progress.notified_at is null
  )
  into rewardable;

  return rewardable;
end;
$$;

revoke all on function public.is_module_rewardable(text) from public;
grant execute on function public.is_module_rewardable(text) to anon, authenticated;

comment on function public.is_module_rewardable(text) is
  'True when the module is completed but its completion notification has not been written yet. False once fully processed.';

-- ---------------------------------------------------------------------------
-- 4. get_module_result
-- ---------------------------------------------------------------------------

-- Review data for a finished module. The analysis text is produced here rather
-- than in the client so a review always says the same thing for the same
-- attempt outcome.
create or replace function public.get_module_result(requested_module_id text)
returns table (
  module_id text,
  module_title text,
  progress_status text,
  score smallint,
  progress_percentage smallint,
  started_at timestamptz,
  completed_at timestamptz,
  attempt_outcome text,
  attempt_completed_at timestamptz,
  analysis text,
  report_id uuid,
  report_title text,
  report_created_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  resolved_user_id uuid := (select auth.uid());
  progress_row public.user_module_progress;
  -- Prefixed so these never shadow the identically named RETURNS TABLE columns
  -- above. The shadowing is currently harmless because the RETURN query reads
  -- the locals, but it is invisible, and a future assignment to one of them
  -- expecting to fill the output row would silently write a dead variable.
  found_outcome text;
  found_attempt_at timestamptz;
  found_report_id uuid;
  found_report_title text;
  found_report_at timestamptz;
  resolved_title text;
  resolved_analysis text;
begin
  if requested_module_id is null then
    return;
  end if;

  select module.title_id
  into resolved_title
  from public.modules as module
  where module.id = requested_module_id;

  if resolved_user_id is not null then
    select *
    into progress_row
    from public.user_module_progress as progress
    where progress.user_id = resolved_user_id
      and progress.module_id = requested_module_id;

    select attempt.outcome, attempt.completed_at
    into found_outcome, found_attempt_at
    from public.practice_attempts as attempt
    where attempt.user_id = resolved_user_id
      and attempt.module_id = requested_module_id
      and attempt.completed_at is not null
    order by attempt.completed_at desc
    limit 1;

    select report.id, report.title, report.created_at
    into found_report_id, found_report_title, found_report_at
    from public.practice_reports as report
    where report.user_id = resolved_user_id
      and report.module_id = requested_module_id
    order by report.created_at desc
    limit 1;
  end if;

  resolved_analysis := case
    when progress_row.user_id is null then null
    when found_outcome is null then 'Modul diselesaikan tanpa catatan hasil attempt.'
    when found_outcome = 'safe' then 'Kamu memverifikasi kanal resmi sebelum bertindak, dan itu langkah yang benar.'
    when found_outcome = 'unsafe' then 'Kamu bertindak pada pesan sebelum memverifikasi kanal resmi. Tinjau ulang langkah verifikasi yang terlewat.'
    when found_outcome = 'mixed' then 'Sebagian langkah sudah benar, sebagian belum. Periksa titik verifikasi sebelum bertindak.'
    else 'Percobaan dicatat tanpa penilaian akhir.'
  end;

  return query
  select
    requested_module_id,
    resolved_title,
    coalesce(progress_row.status, 'not_started'),
    progress_row.score,
    -- Explicit cast: coalesce(smallint, integer) resolves to integer, which
    -- does not match the smallint RETURNS TABLE column.
    coalesce(progress_row.progress_percentage, 0)::smallint,
    progress_row.started_at,
    progress_row.completed_at,
    found_outcome,
    found_attempt_at,
    resolved_analysis,
    found_report_id,
    found_report_title,
    found_report_at;
end;
$$;

revoke all on function public.get_module_result(text) from public;
grant execute on function public.get_module_result(text) to anon, authenticated;

comment on function public.get_module_result(text) is
  'Score, percentage, dates, server-generated analysis and the originating report for a module review.';

-- ---------------------------------------------------------------------------
-- 5. Guard: quest progress only on a first completion
-- ---------------------------------------------------------------------------

-- SECURITY DEFINER because advance_daily_quest is not executable by end users.
-- Nothing caller-controlled reaches it: the only argument is new.user_id, taken
-- from the row being written, so a client cannot steer this at another account.
-- Granting advance_daily_quest to authenticated instead would expose a uuid
-- parameter that credits any user's quest progress.
-- Initial version. Two problems, both fixed in 20260926090000:
--
--   * It advanced a single hardcoded quest id, so a second complete_module quest
--     could never be credited. The short-circuit below was also keyed on that
--     one quest, which meant once it completed, every later module completion
--     returned early and advanced nothing.
--   * advance_daily_quest is revoked from PUBLIC, so this needs SECURITY
--     DEFINER. Nothing caller-controlled reaches it: the only argument is
--     new.user_id, taken from the row being written.
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

  perform public.advance_daily_quest(new.user_id, 'complete-one-module', 1);
  return null;
end;
$$;

drop trigger if exists user_module_progress_guard_quest_progress on public.user_module_progress;
create trigger user_module_progress_guard_quest_progress
  after insert or update of status on public.user_module_progress
  for each row execute function public.guard_module_completion_quest_progress();

revoke all on function public.guard_module_completion_quest_progress() from public;

-- on_module_completed must no longer advance the quest itself, or it would be
-- advanced twice for a single first completion.
create or replace function public.on_module_completed(
  requested_user_id uuid,
  requested_module_id text
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  module_title text;
begin
  if requested_user_id is null or requested_module_id is null then
    return;
  end if;

  perform public.evaluate_achievements(requested_user_id);

  select module.title_id
  into module_title
  from public.modules as module
  where module.id = requested_module_id;

  insert into public.notifications (
    user_id,
    type,
    title,
    body,
    module_id,
    related_id,
    dedupe_key
  )
  values (
    requested_user_id,
    'module_completion',
    'Modul selesai',
    'Kamu menyelesaikan modul "' || coalesce(module_title, requested_module_id) || '". Buka lagi untuk meninjau hasil.',
    requested_module_id,
    requested_module_id,
    'module_completion:' || requested_user_id::text || ':' || requested_module_id
  )
  on conflict (dedupe_key) do nothing;

  update public.user_module_progress
  set notified_at = now()
  where user_id = requested_user_id
    and module_id = requested_module_id
    and notified_at is null;
end;
$$;

revoke all on function public.on_module_completed(uuid, text) from public;

-- ---------------------------------------------------------------------------
-- 6. Guard: repeating a module never advances the practice streak
-- ---------------------------------------------------------------------------

create or replace function public.advance_practice_streak_on_completion()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  resolved_timezone text;
  resolved_date date;
  previous_row public.user_streaks%rowtype;
  next_value integer;
  next_longest integer;
begin
  if new.status is distinct from 'completed' then
    return null;
  end if;

  if tg_op = 'UPDATE' and old.status = 'completed' then
    return null;
  end if;

  select coalesce(profile.timezone, 'Asia/Jakarta')
  into resolved_timezone
  from public.profiles as profile
  where profile.id = new.user_id;

  if resolved_timezone is null then
    return null;
  end if;

  resolved_date := (now() at time zone resolved_timezone)::date;

  select *
  into previous_row
  from public.user_streaks
  where user_id = new.user_id
  for update;

  if not found then
    insert into public.user_streaks (
      user_id,
      current_streak,
      longest_streak,
      freezes_remaining,
      last_qualifying_date,
      last_active_date,
      updated_at
    )
    values (new.user_id, 1, 1, 1, resolved_date, resolved_date, now());

    update public.profiles as profile
    set current_streak = 1,
        longest_streak = 1
    where profile.id = new.user_id;

    return null;
  end if;

  if previous_row.last_qualifying_date = resolved_date then
    return null;
  end if;

  next_value := case
    when previous_row.last_qualifying_date = resolved_date - 1
      then previous_row.current_streak + 1
    else 1
  end;
  next_longest := greatest(previous_row.longest_streak, next_value);

  update public.user_streaks as streak
  set current_streak = next_value,
      longest_streak = next_longest,
      last_qualifying_date = resolved_date,
      last_active_date = resolved_date,
      updated_at = now()
  where streak.user_id = new.user_id;

  -- profiles.current_streak / longest_streak are a denormalised projection read
  -- by the profile page. Keeping them in step here means the client never has
  -- to write them, and therefore never has a chance to get them wrong.
  update public.profiles as profile
  set current_streak = next_value,
      longest_streak = next_longest
  where profile.id = new.user_id;

  return null;
end;
$$;

drop trigger if exists user_module_progress_advance_streak on public.user_module_progress;
create trigger user_module_progress_advance_streak
  after insert or update of status on public.user_module_progress
  for each row execute function public.advance_practice_streak_on_completion();

revoke all on function public.advance_practice_streak_on_completion() from public;

comment on function public.advance_practice_streak_on_completion() is
  'Advances user_streaks only on a first module completion. Replaying a finished module leaves the streak untouched.';
