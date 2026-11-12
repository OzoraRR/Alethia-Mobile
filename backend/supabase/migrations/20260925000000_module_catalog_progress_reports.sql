-- Normalize module progress and move the report hub from local/demo data to
-- durable Supabase state.
--
-- Identity note: Supabase owns credentials in auth.users. public.profiles is
-- the application-facing users table and is kept one-to-one with auth.users by
-- the auth trigger installed in 20260924000000_supabase_auth_profiles.sql.

-- ---------------------------------------------------------------------------
-- Module catalog
-- ---------------------------------------------------------------------------

create table public.modules (
  id text primary key,
  content_key text,
  title_id text not null check (char_length(btrim(title_id)) between 3 and 160),
  title_en text not null check (char_length(btrim(title_en)) between 3 and 160),
  description_id text not null check (char_length(btrim(description_id)) between 10 and 1000),
  description_en text not null check (char_length(btrim(description_en)) between 10 and 1000),
  category text not null check (char_length(btrim(category)) between 2 and 80),
  route text not null unique check (route ~ '^/simulation/[a-z0-9-]+$'),
  image_path text check (image_path is null or image_path ~ '^/media/[a-zA-Z0-9._/-]+$'),
  difficulty smallint not null default 1 check (difficulty between 1 and 5),
  position smallint not null default 0 check (position >= 0),
  is_active boolean not null default true,
  is_published boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint modules_content_key_check check (
    content_key is null or content_key ~ '^[a-z0-9]+(-[a-z0-9]+)*$'
  ),
  constraint modules_published_content_check check (
    is_published = false or (is_active = true and content_key is not null)
  )
);

comment on table public.modules is
  'Canonical training-module catalog. A module is user-visible only when active, published, and linked to real content via content_key.';

-- These are the three implemented training experiences, not placeholder/demo
-- records. No empty future module is inserted into the catalog.
insert into public.modules (
  id,
  content_key,
  title_id,
  title_en,
  description_id,
  description_en,
  category,
  route,
  image_path,
  difficulty,
  position,
  is_active,
  is_published
)
values
  (
    'courier-sms',
    'courier-sms',
    'Courier SMS Phishing',
    'Courier SMS Phishing',
    'Periksa SMS, tautan, dan kanal resmi sebelum mengambil tindakan terhadap permintaan pengiriman.',
    'Inspect an SMS, its link, and an independently opened official channel before acting on a delivery claim.',
    'Smishing',
    '/simulation/courier-sms',
    '/media/sms-phishing.webp',
    3,
    1,
    true,
    true
  ),
  (
    'social-engineering',
    'social-engineering',
    'Marketplace Social Engineering',
    'Marketplace Social Engineering',
    'Petakan jejaring marketplace, transfer kepercayaan, dan mitigasi yang tepat sebelum bertransaksi.',
    'Map a marketplace interaction, trust transfer, and suitable mitigation before completing a transaction.',
    'Marketplace fraud',
    '/simulation/social-engineering',
    '/media/social-engineering.webp',
    4,
    2,
    true,
    true
  ),
  (
    'executable-file',
    'executable-file',
    'Analisis Dokumen Berisiko',
    'Risky Document Analysis',
    'Periksa sumber, konteks, dan ekstensi berkas sebelum membuka atau menjalankan konten.',
    'Check a file source, context, and extension before opening or running its content.',
    'Document analysis',
    '/simulation/executable-file',
    null,
    2,
    3,
    true,
    true
  )
on conflict (id) do update
set content_key = excluded.content_key,
    title_id = excluded.title_id,
    title_en = excluded.title_en,
    description_id = excluded.description_id,
    description_en = excluded.description_en,
    category = excluded.category,
    route = excluded.route,
    image_path = excluded.image_path,
    difficulty = excluded.difficulty,
    position = excluded.position,
    is_active = excluded.is_active,
    is_published = excluded.is_published,
    updated_at = now();

-- ---------------------------------------------------------------------------
-- Relate attempts/progress to the canonical module catalog
-- ---------------------------------------------------------------------------

alter table public.practice_attempts
  drop constraint if exists practice_attempts_module_id_check;

alter table public.practice_attempts
  add constraint practice_attempts_module_id_fkey
  foreign key (module_id) references public.modules (id) on delete restrict;

alter table public.user_module_progress
  drop constraint if exists user_module_progress_module_id_check;

alter table public.user_module_progress
  add column if not exists score smallint,
  add column if not exists progress_percentage smallint not null default 0,
  add column if not exists started_at timestamptz,
  add column if not exists completed_at timestamptz,
  add column if not exists updated_at timestamptz;

update public.user_module_progress
set progress_percentage = case
      when status = 'completed' then 100
      when status = 'in_progress' then greatest(progress_percentage, 1)
      else 0
    end,
    started_at = case
      when status in ('in_progress', 'completed')
        then coalesce(started_at, last_practised_at, now())
      else null
    end,
    completed_at = case
      when status = 'completed'
        then coalesce(completed_at, last_practised_at, now())
      else null
    end,
    updated_at = coalesce(last_practised_at, now());

alter table public.user_module_progress
  alter column updated_at set not null;

alter table public.user_module_progress
  add constraint user_module_progress_module_id_fkey
  foreign key (module_id) references public.modules (id) on delete cascade;

alter table public.user_module_progress
  drop constraint if exists user_module_progress_score_check;

alter table public.user_module_progress
  add constraint user_module_progress_score_check
  check (score is null or score between 0 and 100);

alter table public.user_module_progress
  drop constraint if exists user_module_progress_percentage_check;

alter table public.user_module_progress
  add constraint user_module_progress_percentage_check
  check (progress_percentage between 0 and 100);

alter table public.user_module_progress
  drop constraint if exists user_module_progress_state_check;

alter table public.user_module_progress
  add constraint user_module_progress_state_check
  check (
    (
      status = 'not_started'
      and progress_percentage = 0
      and started_at is null
      and completed_at is null
    )
    or (
      status = 'in_progress'
      and progress_percentage between 1 and 99
      and started_at is not null
      and completed_at is null
    )
    or (
      status = 'completed'
      and progress_percentage = 100
      and started_at is not null
      and completed_at is not null
    )
  );

alter table public.user_module_progress
  drop constraint if exists user_module_progress_completion_order_check;

alter table public.user_module_progress
  add constraint user_module_progress_completion_order_check
  check (completed_at is null or completed_at >= started_at);

create index if not exists user_module_progress_user_status_updated_idx
  on public.user_module_progress (user_id, status, updated_at desc);

create index if not exists practice_attempts_user_module_started_idx
  on public.practice_attempts (user_id, module_id, started_at desc);

-- The count is no longer capped at three: the UI may publish up to six cards,
-- and the database must not reject progress when the catalog grows.
alter table public.profiles
  drop constraint if exists profiles_modules_completed_check;

alter table public.profiles
  add constraint profiles_modules_completed_check
  check (modules_completed >= 0);

-- ---------------------------------------------------------------------------
-- Row timestamps and profile aggregates
-- ---------------------------------------------------------------------------

create or replace function public.set_row_updated_at()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists modules_set_updated_at on public.modules;
create trigger modules_set_updated_at
  before update on public.modules
  for each row execute function public.set_row_updated_at();

drop trigger if exists user_module_progress_set_updated_at on public.user_module_progress;
create trigger user_module_progress_set_updated_at
  before update on public.user_module_progress
  for each row execute function public.set_row_updated_at();

create or replace function public.refresh_profile_module_count()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  affected_user_id uuid;
begin
  if tg_op = 'DELETE' then
    affected_user_id := old.user_id;
  else
    affected_user_id := new.user_id;
  end if;

  update public.profiles as profile
  set modules_completed = (
    select count(*)::integer
    from public.user_module_progress as progress
    join public.modules as module on module.id = progress.module_id
    where progress.user_id = affected_user_id
      and progress.status = 'completed'
      and module.is_active = true
      and module.is_published = true
      and module.content_key is not null
  )
  where profile.id = affected_user_id;

  return null;
end;
$$;

drop trigger if exists user_module_progress_refresh_profile_count on public.user_module_progress;
create trigger user_module_progress_refresh_profile_count
  after insert or update of status or delete on public.user_module_progress
  for each row execute function public.refresh_profile_module_count();

create or replace function public.refresh_all_profile_module_counts()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  update public.profiles as profile
  set modules_completed = (
    select count(*)::integer
    from public.user_module_progress as progress
    join public.modules as module on module.id = progress.module_id
    where progress.user_id = profile.id
      and progress.status = 'completed'
      and module.is_active = true
      and module.is_published = true
      and module.content_key is not null
  );
  return new;
end;
$$;

drop trigger if exists modules_refresh_profile_counts on public.modules;
create trigger modules_refresh_profile_counts
  after update of is_active, is_published, content_key on public.modules
  for each row execute function public.refresh_all_profile_module_counts();

-- Backfill the corrected aggregate once for progress that predates the catalog.
update public.profiles as profile
set modules_completed = (
  select count(*)::integer
  from public.user_module_progress as progress
  join public.modules as module on module.id = progress.module_id
  where progress.user_id = profile.id
    and progress.status = 'completed'
    and module.is_active = true
    and module.is_published = true
    and module.content_key is not null
);

-- Starting a module creates the per-user/per-module row. Reopening a completed
-- module never downgrades it back to in_progress.
create or replace function public.begin_module_progress(requested_module_id text)
returns public.user_module_progress
language plpgsql
security invoker
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
  set status = case
        when progress.status = 'completed' then 'completed'::text
        else 'in_progress'::text
      end,
      progress_percentage = case
        when progress.status = 'completed' then 100
        else greatest(progress.progress_percentage, 1)
      end,
      started_at = now(),
      completed_at = case
        when progress.status = 'completed' then progress.completed_at
        else null
      end,
      updated_at = now()
  returning * into progress_row;

  return progress_row;
end;
$$;

revoke all on function public.begin_module_progress(text) from public;
grant execute on function public.begin_module_progress(text) to authenticated;

-- ---------------------------------------------------------------------------
-- Durable report hub
-- ---------------------------------------------------------------------------

create table public.practice_reports (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles (id) on delete cascade,
  module_id text references public.modules (id) on delete set null,
  attempt_id uuid references public.practice_attempts (id) on delete set null,
  source text not null default 'manual' check (source in ('manual', 'practice_completion')),
  author_username text not null check (author_username ~ '^[A-Za-z0-9_]{3,24}$'),
  title text not null check (char_length(btrim(title)) between 4 and 160),
  category text not null check (category in ('SMS phishing', 'Marketplace scam', 'Account impersonation')),
  channel text not null check (channel in ('Text message', 'Marketplace chat', 'Direct message')),
  pattern text not null check (char_length(btrim(pattern)) between 2 and 120),
  evidence text not null check (char_length(btrim(evidence)) between 10 and 5000),
  why_risky text not null check (char_length(btrim(why_risky)) between 10 and 5000),
  defanged_url text check (defanged_url is null or char_length(defanged_url) <= 2048),
  screenshot_data_url text,
  status text not null default 'Queued for developer review'
    check (status in ('Queued for developer review', 'Triaged', 'Learning note')),
  review_status text not null default 'queued' check (review_status in ('queued', 'approved', 'rejected')),
  reviewed_by uuid references public.profiles (id) on delete set null,
  reviewed_at timestamptz,
  signal_score integer not null default 0 check (signal_score >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint practice_reports_screenshot_check check (
    screenshot_data_url is null
    or (
      screenshot_data_url like 'data:image/%'
      and octet_length(screenshot_data_url) <= 700000
    )
  ),
  constraint practice_reports_review_check check (
    (review_status = 'queued' and reviewed_by is null and reviewed_at is null)
    or (review_status <> 'queued')
  )
);

create table public.report_signals (
  report_id uuid not null references public.practice_reports (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (report_id, user_id)
);

create table public.report_investigation_notes (
  id uuid primary key default gen_random_uuid(),
  report_id uuid not null references public.practice_reports (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  author_role text not null check (author_role in ('student', 'investigator')),
  text text not null check (char_length(btrim(text)) between 4 and 3000),
  created_at timestamptz not null default now()
);

comment on table public.practice_reports is
  'User-authored practice reports backed by Supabase; created_at and signal_score support deterministic sorting.';
comment on column public.practice_reports.signal_score is
  'Cached number of unique report signals, maintained by report_signals.';
comment on column public.practice_reports.screenshot_data_url is
  'Optional data URL for the current 500 KB client limit. Move to Supabase Storage before production-scale media usage.';

create index practice_reports_created_at_idx
  on public.practice_reports (created_at desc, id desc);
create index practice_reports_signal_score_idx
  on public.practice_reports (signal_score desc, created_at desc);
create index practice_reports_review_queue_idx
  on public.practice_reports (review_status, created_at)
  where review_status = 'queued';
create index report_signals_user_created_idx
  on public.report_signals (user_id, created_at desc);
create index report_investigation_notes_report_created_idx
  on public.report_investigation_notes (report_id, created_at);

-- Author identity and immutable server-managed fields are set by the database.
create or replace function public.prepare_practice_report()
returns trigger
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
declare
  resolved_username text;
begin
  if (select auth.uid()) is null then
    raise exception 'AUTHENTICATION_REQUIRED' using errcode = '42501';
  end if;

  select profile.username
  into resolved_username
  from public.profiles as profile
  where profile.id = (select auth.uid());

  if resolved_username is null then
    raise exception 'PROFILE_NOT_FOUND' using errcode = '23503';
  end if;

  new.user_id := (select auth.uid());
  new.author_username := resolved_username;
  new.signal_score := 0;
  new.review_status := 'queued';
  new.reviewed_by := null;
  new.reviewed_at := null;
  new.created_at := now();
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists practice_reports_prepare_insert on public.practice_reports;
create trigger practice_reports_prepare_insert
  before insert on public.practice_reports
  for each row execute function public.prepare_practice_report();

drop trigger if exists practice_reports_set_updated_at on public.practice_reports;
create trigger practice_reports_set_updated_at
  before update on public.practice_reports
  for each row execute function public.set_row_updated_at();

-- signal_score is a cache, so recompute it from the unique signal rows rather
-- than trusting a client-provided counter.
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

  update public.practice_reports
  set signal_score = (
    select count(*)::integer
    from public.report_signals
    where report_id = affected_report_id
  )
  where id = affected_report_id;

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

-- ---------------------------------------------------------------------------
-- Grants and RLS
-- ---------------------------------------------------------------------------

alter table public.modules enable row level security;
alter table public.practice_reports enable row level security;
alter table public.report_signals enable row level security;
alter table public.report_investigation_notes enable row level security;

drop policy if exists modules_select_published on public.modules;
create policy modules_select_published
  on public.modules
  for select
  to anon, authenticated
  using (
    is_active = true
    and is_published = true
    and content_key is not null
  );

drop policy if exists practice_reports_select_authenticated on public.practice_reports;
create policy practice_reports_select_authenticated
  on public.practice_reports
  for select
  to authenticated
  using (true);

drop policy if exists practice_reports_insert_own on public.practice_reports;
create policy practice_reports_insert_own
  on public.practice_reports
  for insert
  to authenticated
  with check (user_id = (select auth.uid()));

drop policy if exists report_signals_select_authenticated on public.report_signals;
create policy report_signals_select_authenticated
  on public.report_signals
  for select
  to authenticated
  using (true);

drop policy if exists report_signals_insert_own on public.report_signals;
create policy report_signals_insert_own
  on public.report_signals
  for insert
  to authenticated
  with check (user_id = (select auth.uid()));

drop policy if exists report_signals_delete_own on public.report_signals;
create policy report_signals_delete_own
  on public.report_signals
  for delete
  to authenticated
  using (user_id = (select auth.uid()));

drop policy if exists report_investigation_notes_select_authenticated on public.report_investigation_notes;
create policy report_investigation_notes_select_authenticated
  on public.report_investigation_notes
  for select
  to authenticated
  using (true);

drop policy if exists report_investigation_notes_insert_own on public.report_investigation_notes;
create policy report_investigation_notes_insert_own
  on public.report_investigation_notes
  for insert
  to authenticated
  with check (user_id = (select auth.uid()));

revoke all on table public.practice_reports from anon;
revoke all on table public.report_signals from anon;
revoke all on table public.report_investigation_notes from anon;

grant select on table public.modules to anon, authenticated;
grant select, insert on table public.practice_reports to authenticated;
grant select, insert, delete on table public.report_signals to authenticated;
grant select, insert on table public.report_investigation_notes to authenticated;
grant select, insert, update on table public.user_module_progress to authenticated;
grant insert on table public.practice_attempts to authenticated;
grant select, update on table public.practice_attempts to authenticated;
grant insert, select on table public.practice_events to authenticated;

revoke all on function public.set_row_updated_at() from public;
revoke all on function public.refresh_profile_module_count() from public;
revoke all on function public.refresh_all_profile_module_counts() from public;
revoke all on function public.prepare_practice_report() from public;
revoke all on function public.sync_report_signal_score() from public;
