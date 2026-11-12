-- Per-user points, a level derived from those points, quest deactivation that
-- actually retires an assignment, and a wider achievement vocabulary.
--
-- Four defects are fixed here.
--
-- 1. Completing a module awarded ZERO points. The only credit path in the whole
--    schema was claim_daily_quest, so a learner who finished all three modules
--    and never claimed a quest had 0 points and nothing to level against. There
--    was also no level at all: `mastery` is a per-module enum, not progression.
--
-- 2. Deactivating a quest did not remove it from a user. admin_apply_quest_definition
--    and ensure_daily_quests_for_user are pure `INSERT ... ON CONFLICT DO NOTHING`,
--    so an assignment row, once created, was permanent for its date. Nothing
--    deleted it and get_dashboard_state never filtered on is_active, so "disable
--    then apply" left the quest on screen. A cold cache reproduced it, so this was
--    never a client caching problem.
--
-- 3. The achievement vocabulary was nine codes with two of them
--    (first_practice and first_module) awarded by the same condition, and nothing
--    recognised per-module, per-quest, or investigation progress.
--
-- 4. daily_quests was not in the realtime publication, so flipping is_active
--    emitted no event and no open tab was ever nudged.

-- ---------------------------------------------------------------------------
-- 1. Module point values
-- ---------------------------------------------------------------------------

-- One place that decides what a module is worth. 20 / 30 / 50 is deliberately
-- uneven: the document module is the deepest, so it is the most expensive.
create or replace function public.module_points(requested_module_id text)
returns integer
language plpgsql
immutable
set search_path = public, pg_temp
as $$
begin
  return case requested_module_id
    when 'courier-sms' then 20
    when 'social-engineering' then 30
    when 'executable-file' then 50
    else 0
  end;
end;
$$;

revoke all on function public.module_points(text) from public;
grant execute on function public.module_points(text) to anon, authenticated, service_role;

comment on function public.module_points(text) is
  'Points awarded for a first completion of a module. 100 points for the whole catalogue.';

-- The ledger reason enum is closed. module_completion has to be in it or
-- award_points raises the check violation and the whole completion aborts.
alter table public.user_point_ledger
  drop constraint if exists user_point_ledger_reason_check;

alter table public.user_point_ledger
  add constraint user_point_ledger_reason_check
  check (reason in ('daily_quest_claim', 'module_completion', 'achievement_reward', 'admin_adjustment'));

-- ---------------------------------------------------------------------------
-- 2. Level
-- ---------------------------------------------------------------------------

-- The curve. 100 points from the full module catalogue plus one full day of
-- daily quests (10 + 50 + 25 = 85) puts a learner who does everything on day
-- one at 185, which is level 3. The first two thresholds are reachable from
-- modules alone; the rest need sustained daily play.
create or replace function public.level_for_points(requested_points integer)
returns integer
language plpgsql
immutable
set search_path = public, pg_temp
as $$
begin
  return case
    when coalesce(requested_points, 0) >= 550 then 5
    when coalesce(requested_points, 0) >= 300 then 4
    when coalesce(requested_points, 0) >= 150 then 3
    when coalesce(requested_points, 0) >= 60 then 2
    else 1
  end;
end;
$$;

revoke all on function public.level_for_points(integer) from public;
grant execute on function public.level_for_points(integer) to anon, authenticated, service_role;

comment on function public.level_for_points(integer) is
  'Level for a point balance. 1..5 with thresholds 0/60/150/300/550.';

alter table public.profiles
  add column if not exists level integer;

update public.profiles as profile
set level = public.level_for_points(profile.points)
where profile.level is distinct from public.level_for_points(profile.points);

alter table public.profiles
  alter column level set default 1;

alter table public.profiles
  alter column level set not null;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'profiles_level_check'
      and conrelid = 'public.profiles'::regclass
  ) then
    alter table public.profiles
      add constraint profiles_level_check
      check (level between 1 and 5);
  end if;
end;
$$;

comment on column public.profiles.level is
  'Level derived from points. Maintained by profiles_sync_level; never written by a client.';

-- A BEFORE trigger that rewrites NEW, not a function the credit paths have to
-- remember to call. award_points, the backfill, and any future writer all get
-- the right level without knowing this exists, and there is no recursion
-- because the trigger never issues its own UPDATE.
create or replace function public.sync_profile_level()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  new.level := public.level_for_points(new.points);
  return new;
end;
$$;

drop trigger if exists profiles_sync_level on public.profiles;
create trigger profiles_sync_level
  before insert or update of points on public.profiles
  for each row execute function public.sync_profile_level();

revoke all on function public.sync_profile_level() from public;

comment on function public.sync_profile_level() is
  'Rewrites profiles.level from profiles.points before every insert and every update that touches points.';

-- ---------------------------------------------------------------------------
-- 3. Points for a first module completion
-- ---------------------------------------------------------------------------

-- Routed through award_points so it shares the same ledger uniqueness key as
-- everything else: (user_id, source_type, source_id). 'module:<id>' is a fixed
-- per-module key, so a replayed completion is a no-op rather than a repeat
-- credit, and there is exactly one ledger row per module per account forever.
create or replace function public.award_module_completion_points(
  requested_user_id uuid,
  requested_module_id text
)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  earned integer;
begin
  if requested_user_id is null or requested_module_id is null then
    return 0;
  end if;

  earned := public.module_points(requested_module_id);

  if earned <= 0 then
    select profile.points
    into earned
    from public.profiles as profile
    where profile.id = requested_user_id;
    return coalesce(earned, 0);
  end if;

  return public.award_points(
    requested_user_id,
    earned,
    'module_completion',
    'module',
    'module:' || requested_module_id
  );
end;
$$;

revoke all on function public.award_module_completion_points(uuid, text) from public;

comment on function public.award_module_completion_points(uuid, text) is
  'Credits a module first-completion point award. Idempotent per (user_id, module_id).';

-- Points land before achievements, so a level-up and its achievement agree
-- within the same transaction. The comment on this function used to claim it
-- was "the single module-completion path: quest progress, achievements,
-- notification, notified_at"; quest progress moved to
-- guard_module_completion_quest_progress and the comment was left behind.
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
  perform public.award_module_completion_points(requested_user_id, requested_module_id);
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
    'Kamu menyelesaikan modul "' || coalesce(module_title, requested_module_id) || '" dan mendapat '
      || public.module_points(requested_module_id)::text || ' poin. Buka lagi untuk meninjau hasil.',
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
  'The single module-completion path: points, achievements, notification, notified_at. Quest progress is advanced separately by guard_module_completion_quest_progress.';

-- ---------------------------------------------------------------------------
-- 4. Achievement vocabulary
-- ---------------------------------------------------------------------------

-- The module -> achievement-code map, so the SQL evaluator and the TypeScript
-- vocabulary cannot drift. NULL for a module with no dedicated achievement.
create or replace function public.module_achievement_code(requested_module_id text)
returns text
language plpgsql
immutable
set search_path = public, pg_temp
as $$
begin
  return case requested_module_id
    when 'courier-sms' then 'module_courier_sms'
    when 'social-engineering' then 'module_social_engineering'
    when 'executable-file' then 'module_executable_file'
    else null
  end;
end;
$$;

revoke all on function public.module_achievement_code(text) from public;
grant execute on function public.module_achievement_code(text) to anon, authenticated, service_role;

-- Streaks stay out of this function. streak_7 is awarded by
-- award_streak_achievement from handle_daily_streak_update, which is the only
-- place that knows a streak reached a threshold. Duplicating the rule here
-- would be two places to keep in step.
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
  investigation_count integer;
  claimed_count integer;
  perfect_date date;
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

  -- One achievement per module, so finishing the third is its own moment
  -- rather than three copies of "you finished something".
  insert into public.user_achievements (user_id, code)
  select requested_user_id, public.module_achievement_code(progress.module_id)
  from public.user_module_progress as progress
  where progress.user_id = requested_user_id
    and progress.status = 'completed'
    and public.module_achievement_code(progress.module_id) is not null
  on conflict (user_id, code) do nothing;

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

  if report_count >= 5 then
    insert into public.user_achievements (user_id, code)
    values (requested_user_id, 'report_analyst')
    on conflict (user_id, code) do nothing;
  end if;

  -- Investigation notes are the investigative work on someone else's report,
  -- which the report counters above never saw.
  select count(*)::integer
  into investigation_count
  from public.report_investigation_notes
  where user_id = requested_user_id;

  if investigation_count >= 1 then
    insert into public.user_achievements (user_id, code)
    values (requested_user_id, 'first_investigation')
    on conflict (user_id, code) do nothing;
  end if;

  if investigation_count >= 5 then
    insert into public.user_achievements (user_id, code)
    values (requested_user_id, 'case_analyst')
    on conflict (user_id, code) do nothing;
  end if;

  -- Daily quest volume.
  select count(*)::integer
  into claimed_count
  from public.user_daily_quests
  where user_id = requested_user_id
    and status = 'claimed';

  if claimed_count >= 1 then
    insert into public.user_achievements (user_id, code)
    values (requested_user_id, 'first_quest_claim')
    on conflict (user_id, code) do nothing;
  end if;

  if claimed_count >= 10 then
    insert into public.user_achievements (user_id, code)
    values (requested_user_id, 'quest_veteran')
    on conflict (user_id, code) do nothing;
  end if;

  -- A cleared day. The condition is "no active quest was left unclaimed on that
  -- date", not "claimed count equals active count": the active set can change
  -- after the day is over, and a quest retired mid-day would otherwise make a
  -- perfect day permanently unearnable. Two is the floor, so one lucky quest
  -- is not a cleared board.
  select assignment.quest_date
  into perfect_date
  from public.user_daily_quests as assignment
  where assignment.user_id = requested_user_id
    and assignment.status = 'claimed'
  group by assignment.quest_date
  having count(*) >= 2
     and not exists (
       select 1
       from public.daily_quests as quest
       where quest.is_active = true
         and not exists (
           select 1
           from public.user_daily_quests as claimed
           where claimed.user_id = requested_user_id
             and claimed.quest_date = assignment.quest_date
             and claimed.quest_id = quest.id
             and claimed.status = 'claimed'
         )
     )
  order by assignment.quest_date desc
  limit 1;

  if perfect_date is not null then
    insert into public.user_achievements (user_id, code)
    values (requested_user_id, 'perfect_day')
    on conflict (user_id, code) do nothing;
  end if;
end;
$$;

revoke all on function public.evaluate_achievements(uuid) from public;

comment on function public.evaluate_achievements(uuid) is
  'Single source of truth for which achievements a user has earned, except streak_7 which award_streak_achievement owns. Called from the module, report, quest-claim and investigation-note paths.';

-- A claim is a real event in the achievement vocabulary, and this trigger is the
-- only place it is observable: claim_daily_quest writes the assignment row and
-- this fires once on the completed -> claimed edge.
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
  if new.status is distinct from 'claimed' or old.status = 'claimed' then
    return null;
  end if;

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

  perform public.evaluate_achievements(new.user_id);

  return null;
end;
$$;

revoke all on function public.handle_daily_quest_claimed() from public;

-- Adding an investigation note was the one investigative action with no
-- achievement hook at all: the note inserted and nothing else happened.
create or replace function public.handle_created_investigation_note()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  perform public.evaluate_achievements(new.user_id);
  return null;
end;
$$;

drop trigger if exists report_investigation_notes_evaluate_achievements
  on public.report_investigation_notes;
create trigger report_investigation_notes_evaluate_achievements
  after insert on public.report_investigation_notes
  for each row execute function public.handle_created_investigation_note();

revoke all on function public.handle_created_investigation_note() from public;

-- The nine new codes used to fall through to the generic 'Achievement Dibuka'
-- string, so unlocking a module-specific badge and unlocking a three-report
-- badge produced the same notification.
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
    when 'module_courier_sms' then 'Modul SMS Kurir'
    when 'module_social_engineering' then 'Modul Social Engineering'
    when 'module_executable_file' then 'Modul Analisis Dokumen'
    when 'all_modules' then 'Katalog Master'
    when 'streak_7' then 'Streak 7 Hari'
    when 'first_report' then 'Pelapor Pertama'
    when 'report_contributor' then 'Kontributor Aktif'
    when 'report_analyst' then 'Analis Laporan'
    when 'first_investigation' then 'Investigasi Pertama'
    when 'case_analyst' then 'Penyusun Kasus'
    when 'first_quest_claim' then 'Quest Pertama'
    when 'quest_veteran' then 'Veteran Quest'
    when 'perfect_day' then 'Hari Sempurna'
    else 'Achievement Dibuka'
  end;

  notification_body := case new.code
    when 'first_module' then 'Kamu telah menyelesaikan modul latihan pertamamu.'
    when 'module_courier_sms' then 'Kamu menuntaskan modul verifikasi SMS kurir.'
    when 'module_social_engineering' then 'Kamu menuntaskan modul social engineering marketplace.'
    when 'module_executable_file' then 'Kamu menuntaskan modul analisis dokumen berisiko.'
    when 'all_modules' then 'Semua modul aktif berhasil kamu selesaikan.'
    when 'streak_7' then 'Kamu aktif tujuh hari berturut-turut.'
    when 'first_report' then 'Laporan pertamamu berhasil disimpan.'
    when 'report_contributor' then 'Kamu sudah menyimpan tiga laporan praktik.'
    when 'report_analyst' then 'Kamu sudah menyimpan lima laporan praktik.'
    when 'first_investigation' then 'Catatan investigasi pertamamu sudah tersimpan.'
    when 'case_analyst' then 'Kamu sudah menulis lima catatan investigasi.'
    when 'first_quest_claim' then 'Quest harian pertamamu sudah diklaim.'
    when 'quest_veteran' then 'Kamu sudah menyelesaikan sepuluh quest harian.'
    when 'perfect_day' then 'Semua quest harianmu hari itu sudah diklaim.'
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
    from public.notifications as notification
    where notification.dedupe_key = 'achievement:' || new.user_id::text || ':' || new.code
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

revoke all on function public.handle_achievement_awarded() from public;

-- ---------------------------------------------------------------------------
-- 5. Deactivating a quest has to retire the assignment
-- ---------------------------------------------------------------------------

-- The catalog join was a LEFT JOIN with no predicate anywhere, and this function
-- is SECURITY DEFINER, so the `daily_quests_select_active` policy that does
-- filter is_active never applied. A quest stayed on the learner's dashboard for
-- the rest of that local day, and claim_daily_quest still paid out for it.
create or replace function public.get_dashboard_state()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  current_user_id uuid := (select auth.uid());
  resolved_timezone text;
  resolved_quest_date date;
  profile_row public.profiles%rowtype;
  practice_streak public.user_streaks%rowtype;
  daily_streak public.user_daily_streaks%rowtype;
  module_rows jsonb;
  quest_rows jsonb;
  achievement_rows jsonb;
  notification_count integer;
  unread_count integer;
  pending_report_count integer;
begin
  if current_user_id is null then
    raise exception 'AUTHENTICATION_REQUIRED' using errcode = '42501';
  end if;

  select *
  into profile_row
  from public.profiles as profile
  where profile.id = current_user_id;

  if profile_row.id is null then
    raise exception 'PROFILE_NOT_FOUND' using errcode = '23503';
  end if;

  resolved_timezone := coalesce(profile_row.timezone, 'Asia/Jakarta');
  resolved_quest_date := (now() at time zone resolved_timezone)::date;

  select *
  into practice_streak
  from public.user_streaks as streak
  where streak.user_id = current_user_id;

  select *
  into daily_streak
  from public.user_daily_streaks as streak
  where streak.user_id = current_user_id;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'module_id', module.id,
        'position', module.position,
        'accessState', public.module_access_state(
          current_user_id,
          module.position,
          coalesce(progress.status, 'not_started')
        ),
        'status', coalesce(progress.status, 'not_started'),
        'progressPercentage', coalesce(progress.progress_percentage, 0),
        'score', progress.score,
        'startedAt', progress.started_at,
        'completedAt', progress.completed_at,
        'notifiedAt', progress.notified_at
      )
      order by module.position
    ),
    '[]'::jsonb
  )
  into module_rows
  from public.modules as module
  left join public.user_module_progress as progress
    on progress.module_id = module.id
   and progress.user_id = current_user_id
  where module.is_active = true
    and module.is_published = true
    and module.content_key is not null;

  -- Only quests the operator has left switched on. `is_active` on the join
  -- target, in the predicate, because a quest row always exists (the assignment
  -- FK is ON DELETE CASCADE) but its flag is what the operator controls.
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', assignment.quest_id,
        'questDate', assignment.quest_date,
        'status', assignment.status,
        'progressValue', assignment.progress_value,
        'targetValue', assignment.target_value,
        'rewardPoints', assignment.reward_points,
        'completedAt', assignment.completed_at,
        'claimedAt', assignment.claimed_at,
        'title', quest.title,
        'description', quest.description,
        'questType', quest.quest_type,
        'position', quest.position
      )
      order by quest.position, assignment.quest_id
    ),
    '[]'::jsonb
  )
  into quest_rows
  from public.user_daily_quests as assignment
  join public.daily_quests as quest
    on quest.id = assignment.quest_id
   and quest.is_active = true
  where assignment.user_id = current_user_id
    and assignment.quest_date = resolved_quest_date;

  select coalesce(
    jsonb_agg(
      jsonb_build_object('code', achievement.code, 'awardedAt', achievement.awarded_at)
      order by achievement.awarded_at desc
    ),
    '[]'::jsonb
  )
  into achievement_rows
  from public.user_achievements as achievement
  where achievement.user_id = current_user_id;

  select
    count(*)::integer,
    count(*) filter (where notification.is_read = false)::integer
  into notification_count, unread_count
  from public.notifications as notification
  where notification.user_id = current_user_id;

  select count(*)::integer
  into pending_report_count
  from public.practice_reports as report
  where report.user_id = current_user_id
    and report.review_status = 'queued';

  return jsonb_build_object(
    'questDate', resolved_quest_date,
    'timezone', resolved_timezone,
    'level', profile_row.level,
    'profile', jsonb_build_object(
      'id', profile_row.id,
      'username', profile_row.username,
      'displayName', profile_row.display_name,
      'preferredLocale', profile_row.preferred_locale,
      'points', profile_row.points,
      'level', profile_row.level,
      'modulesCompleted', profile_row.modules_completed,
      'mastery', profile_row.mastery,
      'badges', to_jsonb(profile_row.badges)
    ),
    'practiceStreak', jsonb_build_object(
      'current', coalesce(practice_streak.current_streak, 0),
      'longest', coalesce(practice_streak.longest_streak, 0),
      'freezesRemaining', coalesce(practice_streak.freezes_remaining, 0),
      'lastQualifyingDate', practice_streak.last_qualifying_date
    ),
    'dailyStreak', jsonb_build_object(
      'current', coalesce(daily_streak.current_streak, 0),
      'longest', coalesce(daily_streak.longest_streak, 0),
      'lastActiveDate', daily_streak.last_active_date
    ),
    'modules', module_rows,
    'quests', quest_rows,
    'achievements', achievement_rows,
    'notifications', jsonb_build_object(
      'total', notification_count,
      'unread', unread_count
    ),
    'reports', jsonb_build_object(
      'pending', pending_report_count
    )
  );
end;
$$;

revoke all on function public.get_dashboard_state() from public;
grant execute on function public.get_dashboard_state() to authenticated;

comment on function public.get_dashboard_state() is
  'Single consistent snapshot of profile, level, module access, streaks, active daily quests, achievements and notification counts.';

-- Defence in depth. The apply below removes unclaimed assignments for a retired
-- quest, so this row should not be reachable; but if a quest is switched off
-- between the removal and a claim, the claim must not pay out.
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

  if not exists (
    select 1
    from public.daily_quests as quest
    where quest.id = requested_quest_id
      and quest.is_active = true
  ) then
    raise exception 'DAILY_QUEST_RETIRED' using errcode = '23514';
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

comment on function public.claim_daily_quest(text, date) is
  'Claims a completed daily quest. Refuses a quest the operator has retired (DAILY_QUEST_RETIRED).';

-- A retired quest must stop accruing progress too. advance_module_quests already
-- filtered on is_active; the report path passed a hardcoded quest id and did not,
-- so a disabled create_report quest kept completing itself.
create or replace function public.advance_daily_quest(
  requested_user_id uuid,
  requested_quest_id text,
  requested_amount integer default 1
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  resolved_timezone text;
  resolved_quest_date date;
begin
  if requested_amount <= 0 then
    return;
  end if;

  select coalesce(profile.timezone, 'Asia/Jakarta')
  into resolved_timezone
  from public.profiles as profile
  where profile.id = requested_user_id;

  if resolved_timezone is null then
    return;
  end if;

  -- Nothing to advance for a quest the operator has switched off.
  if not exists (
    select 1
    from public.daily_quests as quest
    where quest.id = requested_quest_id
      and quest.is_active = true
  ) then
    return;
  end if;

  resolved_quest_date := (now() at time zone resolved_timezone)::date;
  perform public.ensure_daily_quests_for_user(requested_user_id, resolved_quest_date);

  update public.user_daily_quests
  set progress_value = least(progress_value + requested_amount, target_value),
      status = case
        when least(progress_value + requested_amount, target_value) >= target_value
          then 'completed'::text
        else 'in_progress'::text
      end,
      completed_at = case
        when least(progress_value + requested_amount, target_value) >= target_value
          then coalesce(completed_at, now())
        else null
      end,
      updated_at = now()
  where user_id = requested_user_id
    and quest_date = resolved_quest_date
    and quest_id = requested_quest_id
    and status not in ('completed', 'claimed');
end;
$$;

revoke all on function public.advance_daily_quest(uuid, text, integer) from public;

-- The apply was strictly additive. This is the missing DELETE: for the target
-- date, an assignment for a quest that is no longer active is withdrawn, so
-- "disable then apply" actually removes the quest from the learner's board.
--
-- Retired rows are only withdrawn while they are still claimable. A `claimed`
-- row is history: its ledger entry is already booked under
-- 'daily_quest:<date>:<quest>', admin_quest_impact reports pointsPaidOut from
-- that ledger, and deleting the row would silently change a number the operator
-- has already read.
--
-- The return table gains assignments_removed so the operator sees how many
-- assignments the change actually retracted. CREATE OR REPLACE cannot widen a
-- RETURNS TABLE, hence the drop. The removal count is read with `get diagnostics`
-- from the DELETE itself rather than accumulated, so it cannot drift from the
-- rows actually removed.
drop function if exists public.admin_apply_quest_definition(text, date, boolean);

create function public.admin_apply_quest_definition(
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
  assignments_removed integer,
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
  users_total integer := 0;
  already_total integer := 0;
  created_total integer := 0;
  removed_total integer := 0;
  per_user_removed integer;
  per_user_created integer;
  reported_date date;
  user_quest_date date;
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

  reported_date := requested_quest_date;

  for profile_row in
    select profile.id, profile.timezone
    from public.profiles as profile
    order by profile.created_at, profile.id
  loop
    users_total := users_total + 1;

    if reported_date is null then
      reported_date := (now() at time zone profile_row.timezone)::date;
    end if;

    user_quest_date := coalesce(
      requested_quest_date,
      (now() at time zone profile_row.timezone)::date
    );

    if requested_dry_run then
      select count(*)::integer
      into per_user_created
      from public.daily_quests as quest
      where quest.is_active = true
        and not exists (
          select 1
          from public.user_daily_quests as assignment
          where assignment.user_id = profile_row.id
            and assignment.quest_date = user_quest_date
            and assignment.quest_id = quest.id
        );

      if per_user_created = 0 then
        already_total := already_total + 1;
      end if;

      select count(*)::integer
      into per_user_removed
      from public.user_daily_quests as assignment
      join public.daily_quests as quest on quest.id = assignment.quest_id
      where assignment.user_id = profile_row.id
        and assignment.quest_date = user_quest_date
        and assignment.status <> 'claimed'
        and quest.is_active = false;
    else
      delete from public.user_daily_quests as assignment
      using public.daily_quests as quest
      where assignment.quest_id = quest.id
        and assignment.user_id = profile_row.id
        and assignment.quest_date = user_quest_date
        and assignment.status <> 'claimed'
        and quest.is_active = false;

      get diagnostics per_user_removed = row_count;
      removed_total := removed_total + coalesce(per_user_removed, 0);

      per_user_created := public.ensure_daily_quests_for_user(
        profile_row.id,
        user_quest_date
      );

      if per_user_created = 0 then
        already_total := already_total + 1;
      end if;
    end if;

    created_total := created_total + per_user_created;
  end loop;

  if not requested_dry_run then
    perform public.write_admin_audit(
      requested_token,
      'quest.apply_definition',
      'daily_quests',
      coalesce(requested_quest_date::text, 'today'),
      jsonb_build_object(
        'users_processed', users_total,
        'assignments_created', created_total,
        'assignments_removed', removed_total,
        'users_already_assigned', already_total,
        'active_quest_count', active_count
      )
    );
  end if;

  return query
  select
    reported_date,
    active_count,
    users_total,
    created_total,
    already_total,
    removed_total,
    requested_dry_run;
end;
$$;

revoke all on function public.admin_apply_quest_definition(text, date, boolean) from public;
grant execute on function public.admin_apply_quest_definition(text, date, boolean) to anon;

comment on function public.admin_apply_quest_definition(text, date, boolean) is
  'Assigns every active quest to every user for a date, and withdraws unclaimed assignments for quests that are no longer active. Retains claimed rows as history.';

-- One sweep for the whole population, for the scheduled path. Without it a
-- retired quest keeps an assignment for every user who had already been
-- assigned it, until each of them happened to trigger an apply.
create or replace function public.retire_inactive_quest_assignments(requested_quest_date date default null)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  removed_count integer;
begin
  delete from public.user_daily_quests as assignment
  using public.daily_quests as quest
  where assignment.quest_id = quest.id
    and assignment.status <> 'claimed'
    and quest.is_active = false
    and (
      requested_quest_date is null
      or assignment.quest_date = requested_quest_date
    );

  get diagnostics removed_count = row_count;

  return coalesce(removed_count, 0);
end;
$$;

revoke all on function public.retire_inactive_quest_assignments(date) from public;
grant execute on function public.retire_inactive_quest_assignments(date) to service_role;

comment on function public.retire_inactive_quest_assignments(date) is
  'Withdraws unclaimed assignments for retired quests. Withdraws for every date when requested_quest_date is null.';

-- Flipping is_active on the catalog emitted no realtime event, so an open
-- learner tab was never nudged. It is the assignment table the client
-- subscribes to, and nothing wrote to it on deactivation, which is the same
-- root cause as the missing DELETE.
do $$
begin
  if not exists (
    select 1
    from pg_publication_tables
    where pubname = 'supabase_realtime'
      and schemaname = 'public'
      and tablename = 'daily_quests'
  ) then
    execute 'alter publication supabase_realtime add table public.daily_quests';
  end if;
exception
  when others then
    raise notice 'Could not publish daily_quests to supabase_realtime (%).', sqlerrm;
end;
$$;

-- ---------------------------------------------------------------------------
-- 6. Backfill
-- ---------------------------------------------------------------------------

-- Points for modules that were completed before this migration. The ledger key
-- is 'module:<id>', so this is idempotent and cannot double-credit a learner who
-- re-runs a module today.
do $$
declare
  completed_row record;
begin
  for completed_row in
    select progress.user_id, progress.module_id
    from public.user_module_progress as progress
    where progress.status = 'completed'
  loop
    perform public.award_module_completion_points(
      completed_row.user_id,
      completed_row.module_id
    );
  end loop;
end;
$$;

-- The nine new achievements for everyone who already earned them. Without this
-- an established learner opens the grid to a wall of locked badges for work
-- they did months ago.
do $$
declare
  learner_row record;
begin
  for learner_row in select id from public.profiles loop
    perform public.evaluate_achievements(learner_row.id);

    -- streak_7 is owned by award_streak_achievement, not evaluate_achievements.
    perform public.award_streak_achievement(
      learner_row.id,
      coalesce(
        (select current_streak from public.user_daily_streaks where user_id = learner_row.id),
        0
      )
    );
  end loop;
end;
$$;

-- Belt and braces: the trigger is the authority, but a profile row that somehow
-- predates it should still agree with the curve.
update public.profiles as profile
set level = public.level_for_points(profile.points)
where profile.level is distinct from public.level_for_points(profile.points);

-- Any assignment for a quest that was already switched off before this
-- migration, so the bug does not need one more apply to clear.
select public.retire_inactive_quest_assignments(null);

-- ---------------------------------------------------------------------------
-- 7. Grants
-- ---------------------------------------------------------------------------

grant execute on function public.evaluate_achievements(uuid) to service_role;
grant execute on function public.award_module_completion_points(uuid, text) to service_role;
grant execute on function public.module_points(text) to anon, authenticated, service_role;
grant execute on function public.level_for_points(integer) to anon, authenticated, service_role;
grant execute on function public.module_achievement_code(text) to anon, authenticated, service_role;
grant execute on function public.retire_inactive_quest_assignments(date) to service_role;
