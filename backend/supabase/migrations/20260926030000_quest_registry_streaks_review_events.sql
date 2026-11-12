-- Supporting tables for the quest registry, daily streaks, review history and
-- the admin audit trail, plus the module-catalog RPCs that are being retired.
--
--  * quest_event_registry   which application events a quest_type listens to.
--                           daily_quests.quest_type is now a foreign key into
--                           it, so a quest cannot reference an event nothing
--                           emits.
--  * user_daily_streaks     the login streak. Split out from user_streaks,
--                           which tracks module-practice streaks and is written
--                           by the client-side progress layer.
--  * report_review_events   every moderation transition, with the note that
--                           accompanied it.
--  * admin_audit_log        append-only trail of privileged writes.
--  * practice_reports.admin_note  reviewer commentary, moderation-only.

-- ---------------------------------------------------------------------------
-- 1. Quest event registry
-- ---------------------------------------------------------------------------

create table public.quest_event_registry (
  quest_type text primary key check (quest_type ~ '^[a-z]+(_[a-z]+)*$'),
  event_key text not null unique check (char_length(btrim(event_key)) between 1 and 64),
  label text not null check (char_length(btrim(label)) between 2 and 120),
  description text not null check (char_length(btrim(description)) between 10 and 500),
  is_supported boolean not null default true,
  created_at timestamptz not null default now()
);

comment on table public.quest_event_registry is
  'Which application event advances a given quest_type. Referenced by daily_quests.quest_type.';

insert into public.quest_event_registry (quest_type, event_key, label, description, is_supported)
values
  (
    'daily_login',
    'daily_login',
    'Login harian',
    'Tercatat saat pengguna mencatat aktivitas harian pada tanggal lokal mereka.',
    true
  ),
  (
    'complete_module',
    'module_completion',
    'Penyelesaian modul',
    'Tercatat sekali saat sebuah modulodiselesaikan untuk pertama kali.',
    true
  ),
  (
    'create_report',
    'report_creation',
    'Pembuatan laporan',
    'Tercatat sekali untuk setiap laporan praktik yang disimpan.',
    true
  )
on conflict (quest_type) do update
set event_key = excluded.event_key,
    label = excluded.label,
    description = excluded.description,
    is_supported = excluded.is_supported;

alter table public.daily_quests
  drop constraint if exists daily_quests_quest_type_fkey;

alter table public.daily_quests
  add constraint daily_quests_quest_type_fkey
  foreign key (quest_type) references public.quest_event_registry (quest_type)
  on delete restrict;

alter table public.quest_event_registry enable row level security;

drop policy if exists quest_event_registry_select_all on public.quest_event_registry;
create policy quest_event_registry_select_all
  on public.quest_event_registry
  for select
  to anon, authenticated
  using (true);

revoke all on table public.quest_event_registry from anon, authenticated;
grant select on table public.quest_event_registry to anon, authenticated;

-- ---------------------------------------------------------------------------
-- 2. Daily streaks, split from user_streaks
-- ---------------------------------------------------------------------------

create table public.user_daily_streaks (
  user_id uuid primary key references public.profiles (id) on delete cascade,
  current_streak integer not null default 0 check (current_streak >= 0),
  longest_streak integer not null default 0 check (longest_streak >= 0),
  last_active_date date,
  updated_at timestamptz not null default now()
);

comment on table public.user_daily_streaks is
  'Consecutive local calendar days on which the user recorded activity. Distinct from user_streaks, which counts module practice.';

create index user_daily_streaks_last_active_idx
  on public.user_daily_streaks (last_active_date desc);

alter table public.user_daily_streaks enable row level security;

drop policy if exists user_daily_streaks_select_own on public.user_daily_streaks;
create policy user_daily_streaks_select_own
  on public.user_daily_streaks
  for select
  to authenticated
  using (user_id = (select auth.uid()));

revoke all on table public.user_daily_streaks from anon, authenticated;
grant select on table public.user_daily_streaks to authenticated;

-- The streak award follows the daily table now.
drop trigger if exists user_streaks_award_achievement on public.user_streaks;

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

drop trigger if exists user_daily_streaks_award_achievement on public.user_daily_streaks;
create trigger user_daily_streaks_award_achievement
  after insert or update of current_streak on public.user_daily_streaks
  for each row execute function public.handle_daily_streak_update();

-- record_daily_activity now maintains the daily table. The output columns are
-- unchanged so the existing client contract keeps working; the values now come
-- from the daily streak rather than the practice streak.
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
  previous_streak public.user_daily_streaks%rowtype;
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

  -- profiles has no updated_at column and no set_row_updated_at trigger. The
  -- only thing that changes here is the timezone, which the caller is entitled
  -- to correct.
  update public.profiles as profile
  set timezone = resolved_timezone
  where profile.id = current_user_id;

  resolved_quest_date := (now() at time zone resolved_timezone)::date;

  select *
  into previous_streak
  from public.user_daily_streaks
  where user_id = current_user_id
  for update;

  if not found then
    next_streak_value := 1;
    next_longest_value := 1;
    insert into public.user_daily_streaks (
      user_id,
      current_streak,
      longest_streak,
      last_active_date,
      updated_at
    )
    values (
      current_user_id,
      next_streak_value,
      next_longest_value,
      resolved_quest_date,
      now()
    );
  elsif previous_streak.last_active_date = resolved_quest_date then
    next_streak_value := previous_streak.current_streak;
    next_longest_value := previous_streak.longest_streak;
    update public.user_daily_streaks as streak
    set updated_at = now()
    where streak.user_id = current_user_id;
  else
    next_streak_value := case
      when previous_streak.last_active_date = resolved_quest_date - 1
        then previous_streak.current_streak + 1
      else 1
    end;
    next_longest_value := greatest(previous_streak.longest_streak, next_streak_value);
    update public.user_daily_streaks as streak
    set current_streak = next_streak_value,
        longest_streak = next_longest_value,
        last_active_date = resolved_quest_date,
        updated_at = now()
    where streak.user_id = current_user_id;
  end if;

  assigned_count := public.ensure_daily_quests_for_user(current_user_id, resolved_quest_date);

  -- The status expression must read the *new* progress_value. Testing the old
  -- one yields 'in_progress' (0 >= 1 is false) while the SET writes
  -- progress_value = 1, and user_daily_quests_state_check requires
  -- in_progress to have progress_value < target_value. That check violation
  -- aborted the first daily login of every user.
  update public.user_daily_quests as assignment
  set status = 'completed'::text,
      progress_value = assignment.target_value,
      completed_at = coalesce(assignment.completed_at, now()),
      updated_at = now()
  where assignment.user_id = current_user_id
    and assignment.quest_date = resolved_quest_date
    and assignment.quest_id = 'daily-login'
    and assignment.status not in ('completed', 'claimed');

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

-- Carry existing daily streaks over from the practice table so nobody loses a
-- count the first time they log in after this migration.
--
-- user_daily_streaks.user_id references public.profiles while user_streaks
-- references auth.users. The two are kept 1:1 by on_auth_user_created, but the
-- exists() guard makes this safe on a partially populated database instead of
-- aborting the whole migration on one missing profile row.
insert into public.user_daily_streaks (
  user_id,
  current_streak,
  longest_streak,
  last_active_date,
  updated_at
)
select
  streak.user_id,
  streak.current_streak,
  streak.longest_streak,
  streak.last_active_date,
  now()
from public.user_streaks as streak
where streak.last_active_date is not null
  and exists (
    select 1
    from public.profiles as profile
    where profile.id = streak.user_id
  )
on conflict (user_id) do nothing;

revoke all on function public.handle_daily_streak_update() from public;
revoke all on function public.record_daily_activity(text) from public;
grant execute on function public.record_daily_activity(text) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. Review history
-- ---------------------------------------------------------------------------

alter table public.practice_reports
  add column if not exists admin_note text;

alter table public.practice_reports
  drop constraint if exists practice_reports_admin_note_check;

alter table public.practice_reports
  add constraint practice_reports_admin_note_check
  check (admin_note is null or char_length(btrim(admin_note)) <= 2000);

comment on column public.practice_reports.admin_note is
  'Reviewer commentary. Moderation-only: written through admin_update_report, never by the report owner.';

create table public.report_review_events (
  id uuid primary key default gen_random_uuid(),
  report_id uuid not null references public.practice_reports (id) on delete cascade,
  actor_username text not null check (char_length(btrim(actor_username)) between 1 and 64),
  previous_status text,
  previous_review_status text,
  next_status text not null,
  next_review_status text not null,
  note text check (note is null or char_length(btrim(note)) <= 2000),
  created_at timestamptz not null default now()
);

comment on table public.report_review_events is
  'Append-only history of practice_reports moderation transitions, including the reviewer note at the time of the change.';

create index report_review_events_report_created_idx
  on public.report_review_events (report_id, created_at desc);

alter table public.report_review_events enable row level security;

-- No SELECT policy on purpose. actor_username is an admin_accounts username, and
-- the sibling admin_accounts table grants no SELECT to authenticated. A policy
-- here would hand every logged-in user the reviewer identities that
-- admin_accounts deliberately withholds, and every moderation note with them.
-- The only reader is admin_report_review_history, behind a session check.
revoke all on table public.report_review_events from anon, authenticated, service_role;

-- admin_note joins the moderation-only field set.
create or replace function public.protect_practice_report_system_fields()
returns trigger
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
begin
  if current_setting('alethia.admin_action', true) is distinct from 'on'
     and coalesce(auth.role(), current_user) in ('anon', 'authenticated')
     and (
       new.id is distinct from old.id
       or new.user_id is distinct from old.user_id
       or new.author_username is distinct from old.author_username
       or new.source is distinct from old.source
       or new.signal_score is distinct from old.signal_score
       or new.review_status is distinct from old.review_status
       or new.status is distinct from old.status
       or new.reviewed_by is distinct from old.reviewed_by
       or new.reviewed_at is distinct from old.reviewed_at
       or new.admin_note is distinct from old.admin_note
       or new.created_at is distinct from old.created_at
     ) then
    raise exception 'PRACTICE_REPORT_SYSTEM_FIELDS_IMMUTABLE' using errcode = '42501';
  end if;

  new.updated_at := now();
  return new;
end;
$$;

revoke all on function public.protect_practice_report_system_fields() from public;

-- ---------------------------------------------------------------------------
-- 4. Admin audit log
-- ---------------------------------------------------------------------------

create table public.admin_audit_log (
  id bigint generated always as identity primary key,
  actor_username text not null check (char_length(btrim(actor_username)) between 1 and 64),
  action text not null check (char_length(btrim(action)) between 1 and 80),
  target_type text check (target_type is null or char_length(btrim(target_type)) between 1 and 40),
  target_id text check (target_id is null or char_length(btrim(target_id)) between 1 and 200),
  detail jsonb not null default '{}'::jsonb check (jsonb_typeof(detail) = 'object'),
  created_at timestamptz not null default now()
);

comment on table public.admin_audit_log is
  'Append-only trail of privileged admin writes. No insert path is exposed to anon or authenticated.';

create index admin_audit_log_created_idx
  on public.admin_audit_log (created_at desc, id desc);
create index admin_audit_log_actor_idx
  on public.admin_audit_log (actor_username, created_at desc);

alter table public.admin_audit_log enable row level security;

revoke all on table public.admin_audit_log from anon, authenticated, service_role;

create or replace function public.write_admin_audit(
  requested_token text,
  requested_action text,
  requested_target_type text default null,
  requested_target_id text default null,
  requested_detail jsonb default '{}'::jsonb
)
returns bigint
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  session_username text;
  audit_id bigint;
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

  insert into public.admin_audit_log (
    actor_username,
    action,
    target_type,
    target_id,
    detail
  )
  values (
    session_username,
    btrim(requested_action),
    nullif(btrim(coalesce(requested_target_type, '')), ''),
    nullif(btrim(coalesce(requested_target_id, '')), ''),
    coalesce(requested_detail, '{}'::jsonb)
  )
  returning id into audit_id;

  return audit_id;
end;
$$;

revoke all on function public.write_admin_audit(text, text, text, text, jsonb) from public;

-- ---------------------------------------------------------------------------
-- 5. Module-catalog RPCs
-- ---------------------------------------------------------------------------

-- admin_upsert_module and admin_list_modules were already dropped in
-- 20260926010000, before modules.position was pinned and constrained. That
-- ordering was deliberate: the upsert wrote an arbitrary position, so pinning
-- the catalog order while a writer for positions still existed was a race.
--
-- The rationale for removing them at all: module content is identified by
-- content_key and lives in the application, not in the database. An RPC that
-- uploads catalog rows lets a database write publish a module whose content does
-- not exist. Modules are now managed in code and migrated like any other schema
-- change, and the admin console reads the catalog rather than editing it.
