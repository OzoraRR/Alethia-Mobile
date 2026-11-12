-- Daily quests, timezone-aware activity streaks, points, achievements, and
-- in-app notifications.
--
-- Daily quest rows are assigned lazily on a user's first activity of their
-- local day. This is timezone-safe and also works when the application is
-- closed at local midnight. An optional bulk assignment function is included
-- for a pg_cron job.

-- ---------------------------------------------------------------------------
-- User timezone and points
-- ---------------------------------------------------------------------------

alter table public.profiles
  add column if not exists timezone text not null default 'Asia/Jakarta',
  add column if not exists points integer not null default 0;

alter table public.profiles
  drop constraint if exists profiles_timezone_length_check;

alter table public.profiles
  add constraint profiles_timezone_length_check
  check (char_length(timezone) between 1 and 100);

alter table public.profiles
  drop constraint if exists profiles_points_check;

alter table public.profiles
  add constraint profiles_points_check
  check (points >= 0);

alter table public.user_streaks
  add column if not exists last_active_date date;

update public.user_streaks
set last_active_date = last_qualifying_date
where last_active_date is null;

create index if not exists user_streaks_last_active_idx
  on public.user_streaks (last_active_date desc);

create or replace function public.validate_profile_timezone()
returns trigger
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
begin
  if not exists (
    select 1
    from pg_timezone_names
    where name = new.timezone
  ) then
    raise exception 'INVALID_TIMEZONE' using errcode = '22023';
  end if;
  return new;
end;
$$;

drop trigger if exists profiles_validate_timezone on public.profiles;
create trigger profiles_validate_timezone
  before insert or update of timezone on public.profiles
  for each row execute function public.validate_profile_timezone();

-- Existing profile statistics remain browser-writable for compatibility, but
-- points may only be changed by a trusted point-award function.
create or replace function public.protect_profile_points()
returns trigger
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
begin
  if new.points is distinct from old.points
     and current_setting('alethia.point_award', true) is distinct from 'on'
     and coalesce(auth.role(), current_user) in ('anon', 'authenticated') then
    raise exception 'PROFILE_POINTS_IMMUTABLE' using errcode = '42501';
  end if;
  return new;
end;
$$;

drop trigger if exists profiles_protect_points on public.profiles;
create trigger profiles_protect_points
  before update on public.profiles
  for each row execute function public.protect_profile_points();

-- ---------------------------------------------------------------------------
-- Daily quest catalog and per-user assignments
-- ---------------------------------------------------------------------------

create table public.daily_quests (
  id text primary key check (id ~ '^[a-z0-9]+(?:-[a-z0-9]+)*$'),
  title text not null check (char_length(btrim(title)) between 3 and 120),
  description text not null check (char_length(btrim(description)) between 10 and 500),
  quest_type text not null check (quest_type in ('daily_login', 'complete_module', 'create_report')),
  target_value smallint not null default 1 check (target_value between 1 and 1000),
  reward_points integer not null default 0 check (reward_points >= 0),
  position smallint not null default 0 check (position >= 0),
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.daily_quests is
  'Fixed daily quest pool. The current three quests use events supported by the current application.';

create table public.user_daily_quests (
  user_id uuid not null references public.profiles (id) on delete cascade,
  quest_date date not null,
  quest_id text not null references public.daily_quests (id) on delete cascade,
  status text not null default 'not_started'
    check (status in ('not_started', 'in_progress', 'completed', 'claimed')),
  progress_value integer not null default 0 check (progress_value >= 0),
  target_value integer not null check (target_value > 0),
  reward_points integer not null check (reward_points >= 0),
  completed_at timestamptz,
  claimed_at timestamptz,
  updated_at timestamptz not null default now(),
  primary key (user_id, quest_date, quest_id),
  constraint user_daily_quests_state_check check (
    (status = 'not_started' and progress_value = 0 and completed_at is null and claimed_at is null)
    or (
      status = 'in_progress'
      and progress_value >= 1
      and progress_value < target_value
      and completed_at is null
      and claimed_at is null
    )
    or (
      status = 'completed'
      and progress_value >= target_value
      and completed_at is not null
      and claimed_at is null
    )
    or (
      status = 'claimed'
      and progress_value >= target_value
      and completed_at is not null
      and claimed_at is not null
    )
  )
);

comment on table public.user_daily_quests is
  'Timezone-derived local-date assignments and progress for each user daily quest.';

create index user_daily_quests_user_date_status_idx
  on public.user_daily_quests (user_id, quest_date desc, status);
create index user_daily_quests_date_idx
  on public.user_daily_quests (quest_date, status);

insert into public.daily_quests (
  id,
  title,
  description,
  quest_type,
  target_value,
  reward_points,
  position,
  is_active
)
values
  (
    'daily-login',
    'Login Harian',
    'Aktif dan selesaikan login hari ini untuk menjaga streak.',
    'daily_login',
    1,
    10,
    1,
    true
  ),
  (
    'complete-one-module',
    'Tuntaskan Satu Modul',
    'Selesaikan minimal satu modul latihan pada hari ini.',
    'complete_module',
    1,
    50,
    2,
    true
  ),
  (
    'submit-one-report',
    'Kirim Satu Laporan',
    'Buat dan simpan satu laporan praktik dari observasi yang kamu lakukan.',
    'create_report',
    1,
    25,
    3,
    true
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

drop trigger if exists daily_quests_set_updated_at on public.daily_quests;
create trigger daily_quests_set_updated_at
  before update on public.daily_quests
  for each row execute function public.set_row_updated_at();

-- ---------------------------------------------------------------------------
-- Point ledger and in-app notifications
-- ---------------------------------------------------------------------------

create table public.user_point_ledger (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  amount integer not null check (amount > 0),
  reason text not null check (reason in ('daily_quest_claim', 'achievement_reward', 'admin_adjustment')),
  reference_type text not null check (char_length(btrim(reference_type)) between 1 and 64),
  reference_key text not null check (char_length(btrim(reference_key)) between 1 and 200),
  created_at timestamptz not null default now(),
  constraint user_point_ledger_reference_unique unique (user_id, reference_key)
);

comment on table public.user_point_ledger is
  'Idempotent point award history. Clients can read their own rows but cannot insert or update them.';

create table public.notifications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  type text not null check (type in ('module_completion', 'achievement', 'daily_quest', 'system')),
  title text not null check (char_length(btrim(title)) between 1 and 160),
  body text not null check (char_length(btrim(body)) between 1 and 1000),
  module_id text references public.modules (id) on delete set null,
  achievement_code text,
  related_id text,
  dedupe_key text not null check (char_length(btrim(dedupe_key)) between 1 and 200),
  is_read boolean not null default false,
  read_at timestamptz,
  created_at timestamptz not null default now(),
  constraint notifications_dedupe_unique unique (user_id, dedupe_key),
  constraint notifications_read_check check (
    (is_read = true and read_at is not null)
    or (is_read = false and read_at is null)
  )
);

comment on table public.notifications is
  'In-app notifications. Type separates module completion from achievements; dedupe_key prevents duplicate events.';

create index notifications_user_unread_created_idx
  on public.notifications (user_id, is_read, created_at desc);
create index notifications_user_created_idx
  on public.notifications (user_id, created_at desc);

-- ---------------------------------------------------------------------------
-- Timezone-aware quest assignment and daily streak logic
-- ---------------------------------------------------------------------------

create or replace function public.ensure_daily_quests_for_user(
  requested_user_id uuid,
  requested_quest_date date
)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  inserted_count integer;
begin
  insert into public.user_daily_quests (
    user_id,
    quest_date,
    quest_id,
    status,
    progress_value,
    target_value,
    reward_points,
    updated_at
  )
  select
    requested_user_id,
    requested_quest_date,
    quest.id,
    'not_started',
    0,
    quest.target_value,
    quest.reward_points,
    now()
  from public.daily_quests as quest
  where quest.is_active = true
  on conflict (user_id, quest_date, quest_id) do nothing;

  get diagnostics inserted_count = row_count;
  return inserted_count;
end;
$$;

create or replace function public.record_daily_activity(
  requested_timezone text default null
)
returns table (
  quest_date date,
  current_streak integer,
  longest_streak integer,
  points integer,
  newly_assigned_quests integer
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  current_user_id uuid := (select auth.uid());
  resolved_timezone text;
  resolved_quest_date date;
  assigned_count integer;
  previous_streak public.user_streaks%rowtype;
  next_streak_value integer;
  next_longest_value integer;
  total_points integer;
begin
  if current_user_id is null then
    raise exception 'AUTHENTICATION_REQUIRED' using errcode = '42501';
  end if;

  select coalesce(
    nullif(btrim(requested_timezone), ''),
    profile.timezone,
    'Asia/Jakarta'
  )
  into resolved_timezone
  from public.profiles as profile
  where profile.id = current_user_id;

  if resolved_timezone is null then
    resolved_timezone := 'Asia/Jakarta';
  end if;

  if not exists (
    select 1
    from pg_timezone_names
    where name = resolved_timezone
  ) then
    raise exception 'INVALID_TIMEZONE' using errcode = '22023';
  end if;

  update public.profiles
  set timezone = resolved_timezone
  where id = current_user_id;

  resolved_quest_date := (now() at time zone resolved_timezone)::date;

  select *
  into previous_streak
  from public.user_streaks
  where user_id = current_user_id
  for update;

  if not found then
    next_streak_value := 1;
    next_longest_value := 1;
    insert into public.user_streaks (
      user_id,
      current_streak,
      longest_streak,
      freezes_remaining,
      last_active_date,
      updated_at
    )
    values (
      current_user_id,
      next_streak_value,
      next_longest_value,
      1,
      resolved_quest_date,
      now()
    );
  elsif previous_streak.last_active_date = resolved_quest_date then
    next_streak_value := previous_streak.current_streak;
    next_longest_value := previous_streak.longest_streak;
    update public.user_streaks
    set updated_at = now()
    where user_id = current_user_id;
  else
    next_streak_value := case
      when previous_streak.last_active_date = resolved_quest_date - 1
        then previous_streak.current_streak + 1
      else 1
    end;
    next_longest_value := greatest(previous_streak.longest_streak, next_streak_value);
    update public.user_streaks
    set current_streak = next_streak_value,
        longest_streak = next_longest_value,
        last_active_date = resolved_quest_date,
        updated_at = now()
    where user_id = current_user_id;
  end if;

  assigned_count := public.ensure_daily_quests_for_user(current_user_id, resolved_quest_date);

  update public.user_daily_quests
  set status = case
        when progress_value >= target_value then 'completed'::text
        else 'in_progress'::text
      end,
      progress_value = target_value,
      completed_at = coalesce(completed_at, now()),
      updated_at = now()
  where user_id = current_user_id
    and quest_date = resolved_quest_date
    and quest_id = 'daily-login'
    and status not in ('completed', 'claimed');

  select profile.points
  into total_points
  from public.profiles as profile
  where profile.id = current_user_id;

  return query
  select
    resolved_quest_date,
    next_streak_value,
    next_longest_value,
    coalesce(total_points, 0),
    assigned_count;
end;
$$;

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

create or replace function public.assign_daily_quests_for_all_users()
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  profile_row record;
  total_assigned integer := 0;
  current_assigned integer;
begin
  for profile_row in
    select id, timezone
    from public.profiles
  loop
    current_assigned := public.ensure_daily_quests_for_user(
      profile_row.id,
      (now() at time zone profile_row.timezone)::date
    );
    total_assigned := total_assigned + current_assigned;
  end loop;

  return total_assigned;
end;
$$;

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
  profile_points integer;
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
    select profile.points into profile_points
    from public.profiles as profile
    where profile.id = current_user_id;
    return query select 'claimed'::text, 0, coalesce(profile_points, 0);
    return;
  end if;

  if quest_row.status <> 'completed' then
    raise exception 'DAILY_QUEST_NOT_COMPLETED' using errcode = '23514';
  end if;

  claim_reference := 'daily_quest:' || requested_quest_date::text || ':' || requested_quest_id;
  awarded_points := quest_row.reward_points;
  perform set_config('alethia.point_award', 'on', true);

  if awarded_points > 0 then
    insert into public.user_point_ledger (
      user_id,
      amount,
      reason,
      reference_type,
      reference_key
    )
    values (
      current_user_id,
      awarded_points,
      'daily_quest_claim',
      'daily_quest',
      claim_reference
    )
    on conflict (user_id, reference_key) do nothing;

    update public.profiles
    set points = points + awarded_points
    where id = current_user_id;
  end if;

  update public.user_daily_quests
  set status = 'claimed',
      claimed_at = coalesce(claimed_at, now()),
      updated_at = now()
  where user_id = current_user_id
    and quest_date = requested_quest_date
    and quest_id = requested_quest_id;

  perform set_config('alethia.point_award', 'off', true);

  select profile.points into profile_points
  from public.profiles as profile
  where profile.id = current_user_id;

  return query select 'claimed'::text, awarded_points, coalesce(profile_points, 0);
end;
$$;

-- ---------------------------------------------------------------------------
-- Achievement award helpers
-- ---------------------------------------------------------------------------

create or replace function public.award_progress_achievements(requested_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if exists (
    select 1
    from public.user_module_progress
    where user_id = requested_user_id
      and status = 'completed'
  ) then
    insert into public.user_achievements (user_id, code)
    values
      (requested_user_id, 'first_practice'),
      (requested_user_id, 'first_module')
    on conflict (user_id, code) do nothing;
  end if;

  if (
    select count(*)::integer
    from public.modules
    where is_active = true
      and is_published = true
      and content_key is not null
  ) > 0
  and (
    select count(*)::integer
    from public.user_module_progress as progress
    join public.modules as module on module.id = progress.module_id
    where progress.user_id = requested_user_id
      and progress.status = 'completed'
      and module.is_active = true
      and module.is_published = true
      and module.content_key is not null
  ) = (
    select count(*)::integer
    from public.modules
    where is_active = true
      and is_published = true
      and content_key is not null
  ) then
    insert into public.user_achievements (user_id, code)
    values (requested_user_id, 'all_modules')
    on conflict (user_id, code) do nothing;
  end if;
end;
$$;

create or replace function public.award_streak_achievement(
  requested_user_id uuid,
  reached_streak integer
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if reached_streak >= 7 then
    insert into public.user_achievements (user_id, code)
    values (requested_user_id, 'streak_7')
    on conflict (user_id, code) do nothing;
  end if;
end;
$$;

create or replace function public.award_report_achievements(requested_user_id uuid)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  report_count integer;
begin
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

-- ---------------------------------------------------------------------------
-- Automatic quest progress and notifications
-- ---------------------------------------------------------------------------

create or replace function public.handle_completed_module()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  module_title text;
begin
  if tg_op = 'UPDATE' then
    if old.status = 'completed' then
      return null;
    end if;
  end if;

  if new.status <> 'completed' then
    return null;
  end if;

  perform public.advance_daily_quest(new.user_id, 'complete-one-module', 1);
  perform public.award_progress_achievements(new.user_id);

  select module.title_id
  into module_title
  from public.modules as module
  where module.id = new.module_id;

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
    new.user_id,
    'module_completion',
    'Modul selesai!',
    'Kamu berhasil menyelesaikan modul "' || coalesce(module_title, new.module_id) || '".',
    new.module_id,
    new.module_id,
    'module_completion:' || new.user_id::text || ':' || new.module_id
  )
  on conflict (user_id, dedupe_key) do nothing;

  return null;
end;
$$;

drop trigger if exists user_module_progress_handle_completion on public.user_module_progress;
create trigger user_module_progress_handle_completion
  after insert or update of status on public.user_module_progress
  for each row execute function public.handle_completed_module();

create or replace function public.handle_created_report()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  perform public.advance_daily_quest(new.user_id, 'submit-one-report', 1);
  perform public.award_report_achievements(new.user_id);
  return null;
end;
$$;

drop trigger if exists practice_reports_handle_created on public.practice_reports;
create trigger practice_reports_handle_created
  after insert on public.practice_reports
  for each row execute function public.handle_created_report();

create or replace function public.handle_daily_streak_update()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  perform public.award_streak_achievement(new.user_id, new.current_streak);
  return null;
end;
$$;

drop trigger if exists user_streaks_award_achievement on public.user_streaks;
create trigger user_streaks_award_achievement
  after insert or update of current_streak on public.user_streaks
  for each row execute function public.handle_daily_streak_update();

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
    when 'streak_7' then 'Kamu aktif tujuh hari berturut-turut. Pertahankan ritmemu.'
    when 'first_report' then 'Laporan pertamamu berhasil disimpan ke database.'
    when 'report_contributor' then 'Kamu sudah menyimpan tiga laporan praktik.'
    else 'Achievement baru telah terbuka di profilmu.'
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
  on conflict (user_id, dedupe_key) do nothing;

  return null;
end;
$$;

drop trigger if exists user_achievements_create_notification on public.user_achievements;
create trigger user_achievements_create_notification
  after insert on public.user_achievements
  for each row execute function public.handle_achievement_awarded();

create or replace function public.mark_notification_read(requested_notification_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  current_user_id uuid := (select auth.uid());
  changed_id uuid;
begin
  if current_user_id is null then
    raise exception 'AUTHENTICATION_REQUIRED' using errcode = '42501';
  end if;

  update public.notifications
  set is_read = true,
      read_at = coalesce(read_at, now())
  where id = requested_notification_id
    and user_id = current_user_id
    and is_read = false
  returning id into changed_id;

  return changed_id is not null;
end;
$$;

-- ---------------------------------------------------------------------------
-- RLS and grants
-- ---------------------------------------------------------------------------

alter table public.daily_quests enable row level security;
alter table public.user_daily_quests enable row level security;
alter table public.user_point_ledger enable row level security;
alter table public.notifications enable row level security;

drop policy if exists daily_quests_select_active on public.daily_quests;
create policy daily_quests_select_active
  on public.daily_quests
  for select
  to anon, authenticated
  using (is_active = true);

drop policy if exists user_daily_quests_select_own on public.user_daily_quests;
create policy user_daily_quests_select_own
  on public.user_daily_quests
  for select
  to authenticated
  using (user_id = (select auth.uid()));

drop policy if exists user_point_ledger_select_own on public.user_point_ledger;
create policy user_point_ledger_select_own
  on public.user_point_ledger
  for select
  to authenticated
  using (user_id = (select auth.uid()));

drop policy if exists notifications_select_own on public.notifications;
create policy notifications_select_own
  on public.notifications
  for select
  to authenticated
  using (user_id = (select auth.uid()));

revoke all on table public.daily_quests from anon, authenticated;
revoke all on table public.user_daily_quests from anon, authenticated;
revoke all on table public.user_point_ledger from anon, authenticated;
revoke all on table public.notifications from anon, authenticated;

grant select on table public.daily_quests to anon, authenticated;
grant select on table public.user_daily_quests to authenticated;
grant select on table public.user_point_ledger to authenticated;
grant select on table public.notifications to authenticated;

revoke all on function public.validate_profile_timezone() from public;
revoke all on function public.protect_profile_points() from public;
revoke all on function public.ensure_daily_quests_for_user(uuid, date) from public;
revoke all on function public.advance_daily_quest(uuid, text, integer) from public;
revoke all on function public.award_progress_achievements(uuid) from public;
revoke all on function public.award_streak_achievement(uuid, integer) from public;
revoke all on function public.award_report_achievements(uuid) from public;
revoke all on function public.handle_completed_module() from public;
revoke all on function public.handle_created_report() from public;
revoke all on function public.handle_daily_streak_update() from public;
revoke all on function public.handle_achievement_awarded() from public;

revoke all on function public.record_daily_activity(text) from public;
grant execute on function public.record_daily_activity(text) to authenticated;

revoke all on function public.claim_daily_quest(text, date) from public;
grant execute on function public.claim_daily_quest(text, date) to authenticated;

revoke all on function public.mark_notification_read(uuid) from public;
grant execute on function public.mark_notification_read(uuid) to authenticated;

revoke all on function public.assign_daily_quests_for_all_users() from public;
grant execute on function public.assign_daily_quests_for_all_users() to service_role;
