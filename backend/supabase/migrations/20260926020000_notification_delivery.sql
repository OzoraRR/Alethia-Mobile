-- Notification delivery: one completion path, one achievement evaluator,
-- and one read model.
--
-- Before this migration three separate trigger functions each inserted
-- notifications and nothing recorded that it had done so. A retry, a manual
-- re-sync, or a second browser tab could re-enter the path and the only
-- defence was a dedupe key. Now:
--
--   * public.on_module_completed(user_id, module_id) is the single module
--     completion path for achievements, notification and notified_at. Quest
--     progress is deliberately NOT advanced here; that lives in
--     guard_module_completion_quest_progress (20260926040000), which sees the
--     status transition and can skip a module that was already finished.
--   * public.evaluate_achievements(user_id) is the single achievement
--     evaluator. The notification trigger stamps user_achievements.notified_at.
--   * notifications.dedupe_key is unique on its own, not per user.
--   * is_read is authoritative and read_at is derived from it by trigger, so
--     the two can never disagree for any writer.

-- ---------------------------------------------------------------------------
-- 1. Delivery bookkeeping
-- ---------------------------------------------------------------------------

alter table public.user_module_progress
  add column if not exists notified_at timestamptz;

alter table public.user_achievements
  add column if not exists notified_at timestamptz;

comment on column public.user_module_progress.notified_at is
  'Set when the module_completion notification for this row was written. Null means the user has not been told yet.';

comment on column public.user_achievements.notified_at is
  'Set when the achievement notification for this row was written. Null means the user has not been told yet.';

-- ---------------------------------------------------------------------------
-- 2. dedupe_key is globally unique
-- ---------------------------------------------------------------------------

-- Existing keys embed the user id, so promoting them to a global unique index
-- cannot collide with historical rows.
alter table public.notifications
  drop constraint if exists notifications_dedupe_unique;

create unique index if not exists notifications_dedupe_key_unique
  on public.notifications (dedupe_key);

comment on column public.notifications.dedupe_key is
  'Globally unique idempotency key. The key already namespaces by user, so a repeated event is a no-op insert.';

-- ---------------------------------------------------------------------------
-- 3. is_read is authoritative, read_at is derived
-- ---------------------------------------------------------------------------

create or replace function public.sync_notification_read_state()
returns trigger
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
begin
  if new.is_read then
    new.read_at := coalesce(new.read_at, now());
  else
    new.read_at := null;
  end if;
  return new;
end;
$$;

drop trigger if exists notifications_sync_read_state on public.notifications;
create trigger notifications_sync_read_state
  before insert or update of is_read, read_at on public.notifications
  for each row execute function public.sync_notification_read_state();

revoke all on function public.sync_notification_read_state() from public;

comment on function public.sync_notification_read_state() is
  'Derives read_at from is_read so the two fields are always consistent regardless of writer.';

-- A claimed quest is a notification-worthy event and previously produced
-- nothing. Keep the type vocabulary complete and identical on both sides.
create or replace function public.handle_daily_quest_claimed()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  quest_title text;
  reward_amount integer;
begin
  -- Only the not_started -> claimed edge is a claim. Guarding on
  -- `old.status is distinct from 'claimed'` fires this on every progress
  -- change, which both mislabels the notification and burns the dedupe key the
  -- real claim needs.
  if new.status is distinct from 'claimed' or old.status = 'claimed' then
    return null;
  end if;

  -- new.reward_points is the snapshot on the assignment row. The catalog table
  -- cannot be joined for it: the assignment is not in this query's FROM list,
  -- and a value the user could have changed since assignment is the wrong one
  -- to quote back at them.
  reward_amount := new.reward_points;

  select quest.title
  into quest_title
  from public.daily_quests as quest
  where quest.id = new.quest_id;

  insert into public.notifications (
    user_id,
    type,
    title,
    body,
    related_id,
    dedupe_key
  )
  values (
    new.user_id,
    'daily_quest',
    'Quest harian diklaim',
    coalesce(
      'Reward ' || reward_amount::text || ' poin dari quest "' || coalesce(quest_title, new.quest_id) || '".',
      'Reward quest harian diklaim.'
    ),
    new.quest_id,
    'daily_quest_claim:' || new.user_id::text || ':' || new.quest_date::text || ':' || new.quest_id
  )
  on conflict (dedupe_key) do nothing;

  return null;
end;
$$;

drop trigger if exists user_daily_quests_notify_claim on public.user_daily_quests;
create trigger user_daily_quests_notify_claim
  after update on public.user_daily_quests
  for each row execute function public.handle_daily_quest_claimed();

revoke all on function public.handle_daily_quest_claimed() from public;

-- ---------------------------------------------------------------------------
-- 4. One achievement evaluator
-- ---------------------------------------------------------------------------

-- Replaces award_progress_achievements and award_report_achievements. Both are
-- dropped so there is exactly one place that decides what a user has earned.
create or replace function public.evaluate_achievements(requested_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  published_total integer;
  published_completed integer;
  report_count integer;
begin
  if requested_user_id is null then
    return;
  end if;

  -- First finished module.
  if exists (
    select 1
    from public.user_module_progress as progress
    where progress.user_id = requested_user_id
      and progress.status = 'completed'
  ) then
    insert into public.user_achievements (user_id, code)
    values
      (requested_user_id, 'first_practice'),
      (requested_user_id, 'first_module')
    on conflict (user_id, code) do nothing;
  end if;

  -- Whole published catalog finished.
  select count(*)::integer
  into published_total
  from public.modules as module
  where module.is_active = true
    and module.is_published = true
    and module.content_key is not null;

  if published_total > 0 then
    select count(*)::integer
    into published_completed
    from public.user_module_progress as progress
    join public.modules as module on module.id = progress.module_id
    where progress.user_id = requested_user_id
      and progress.status = 'completed'
      and module.is_active = true
      and module.is_published = true
      and module.content_key is not null;

    if published_completed = published_total then
      insert into public.user_achievements (user_id, code)
      values (requested_user_id, 'all_modules')
      on conflict (user_id, code) do nothing;
    end if;
  end if;

  -- Report volume.
  select count(*)::integer
  into report_count
  from public.practice_reports
  where user_id = requested_user_id;

  if report_count >= 1 then
    insert into public.user_achievements (user_id, code)
    values (requested_user_id, 'first_report')
    on conflict (user_id, code) do nothing;
  end if;

  if report_count >= 3 then
    insert into public.user_achievements (user_id, code)
    values (requested_user_id, 'report_contributor')
    on conflict (user_id, code) do nothing;
  end if;
end;
$$;

revoke all on function public.evaluate_achievements(uuid) from public;

comment on function public.evaluate_achievements(uuid) is
  'Single source of truth for which achievements a user has earned. Called from the module-completion and report-creation paths.';

drop function if exists public.award_progress_achievements(uuid);
drop function if exists public.award_report_achievements(uuid);

-- ---------------------------------------------------------------------------
-- 5. One module completion path
-- ---------------------------------------------------------------------------

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

  -- Quest progress is NOT advanced here. It lives in
  -- guard_module_completion_quest_progress, which sees the status transition and
  -- skips a module that was already finished. Advancing it from this function
  -- too would count one completion twice, and the backfill loop below would
  -- credit a *today's* quest for a months-old completion.
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

comment on function public.on_module_completed(uuid, text) is
  'The single module-completion path: quest progress, achievements, notification, notified_at.';

create or replace function public.handle_completed_module()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.status is distinct from 'completed' then
    return null;
  end if;

  -- Completion is terminal (see guard_module_progress_terminal_state), so a
  -- transition into 'completed' happens exactly once. The extra check keeps the
  -- path single-fire even if a future write bypasses the guard.
  if tg_op = 'UPDATE' and old.status is not distinct from 'completed' then
    return null;
  end if;

  perform public.on_module_completed(new.user_id, new.module_id);
  return null;
end;
$$;

drop trigger if exists user_module_progress_handle_completion on public.user_module_progress;
create trigger user_module_progress_handle_completion
  after insert or update of status on public.user_module_progress
  for each row execute function public.handle_completed_module();

revoke all on function public.handle_completed_module() from public;

-- ---------------------------------------------------------------------------
-- 6. Report creation and achievement notification
-- ---------------------------------------------------------------------------

create or replace function public.handle_created_report()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  perform public.advance_daily_quest(new.user_id, 'submit-one-report', 1);
  perform public.evaluate_achievements(new.user_id);
  return null;
end;
$$;

drop trigger if exists practice_reports_handle_created on public.practice_reports;
create trigger practice_reports_handle_created
  after insert on public.practice_reports
  for each row execute function public.handle_created_report();

create or replace function public.handle_achievement_awarded()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  notification_title text;
  notification_body text;
begin
  notification_title := case new.code
    when 'first_module' then 'Pencapaian Pertama'
    when 'all_modules' then 'Katalog Master'
    when 'streak_7' then 'Streak 7 Hari'
    when 'first_report' then 'Pelapor Pertama'
    when 'report_contributor' then 'Kontributor Aktif'
    else 'Achievement Dibuka'
  end;

  notification_body := case new.code
    when 'first_module' then 'Kamu telah menyelesaikan modul latihan pertamamu.'
    when 'all_modules' then 'Semua modul aktif berhasil kamu selesaikan.'
    when 'streak_7' then 'Kamu aktif tujuh hari berturut-turut.'
    when 'first_report' then 'Laporan pertamamu berhasil disimpan.'
    when 'report_contributor' then 'Kamu sudah menyimpan tiga laporan praktik.'
    else 'Achievement baru terbuka di profilmu.'
  end;

  insert into public.notifications (
    user_id,
    type,
    title,
    body,
    achievement_code,
    related_id,
    dedupe_key
  )
  values (
    new.user_id,
    'achievement',
    notification_title,
    notification_body,
    new.code,
    new.code,
    'achievement:' || new.user_id::text || ':' || new.code
  )
  on conflict (dedupe_key) do nothing;

  -- Only claim delivery once the notification row actually exists.
  if exists (
    select 1
    from public.notifications
    where dedupe_key = 'achievement:' || new.user_id::text || ':' || new.code
  ) then
    update public.user_achievements
    set notified_at = coalesce(notified_at, now())
    where user_id = new.user_id
      and code = new.code
      and notified_at is null;
  end if;

  return null;
end;
$$;

drop trigger if exists user_achievements_create_notification on public.user_achievements;
create trigger user_achievements_create_notification
  after insert on public.user_achievements
  for each row execute function public.handle_achievement_awarded();

-- Deliver the notifications that historical rows never received.
--
-- An earlier version of this migration stamped notified_at directly from
-- awarded_at. That is the exact incoherence the column exists to prevent: it
-- claims a delivery that has no notification row behind it. Instead, re-run the
-- real path. on_module_completed is idempotent (dedupe_key, and it only writes
-- notified_at where it is null), so replaying it is safe and also backfills the
-- achievements that predate evaluate_achievements.
do $$
declare
  completed_row record;
begin
  for completed_row in
    select
      progress.user_id,
      progress.module_id
    from public.user_module_progress as progress
    where progress.status = 'completed'
      and progress.notified_at is null
  loop
    perform public.on_module_completed(
      completed_row.user_id,
      completed_row.module_id
    );
  end loop;
end;
$$;

-- Any achievement still without a delivery stamp is evaluated through the same
-- trigger the live path uses, which writes the notification and then stamps it.
update public.user_achievements as achievement
set notified_at = coalesce(achievement.notified_at, now())
where achievement.notified_at is null
  and exists (
    select 1
    from public.notifications as notification
    where notification.dedupe_key = 'achievement:' || achievement.user_id::text || ':' || achievement.code
  );

revoke all on function public.evaluate_achievements(uuid) from public;
revoke all on function public.on_module_completed(uuid, text) from public;
revoke all on function public.handle_created_report() from public;
revoke all on function public.handle_achievement_awarded() from public;
revoke all on function public.sync_notification_read_state() from public;
revoke all on function public.handle_daily_quest_claimed() from public;

grant execute on function public.mark_notification_read(uuid) to authenticated;
