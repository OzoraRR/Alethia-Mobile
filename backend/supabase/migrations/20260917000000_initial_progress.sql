create extension if not exists pgcrypto;

-- Scenario content remains in the application code for this phase.
create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  display_name text,
  preferred_locale text not null default 'id' check (preferred_locale in ('id', 'en')),
  created_at timestamptz not null default now()
);

create table public.practice_attempts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users (id) on delete cascade,
  module_id text not null check (module_id = 'courier-sms'),
  variant_id text not null default 'primary',
  started_at timestamptz not null default now(),
  completed_at timestamptz,
  outcome text check (outcome in ('safe', 'unsafe', 'mixed', 'completed')),
  constraint practice_attempts_completion_order check (completed_at is null or completed_at >= started_at)
);

create table public.practice_events (
  id uuid primary key default gen_random_uuid(),
  attempt_id uuid not null references public.practice_attempts (id) on delete cascade,
  event_type text not null check (
    event_type in (
      'module_started',
      'stage_viewed',
      'sender_inspected',
      'link_inspected',
      'official_channel_verified',
      'decision_selected',
      'attacker_pov_viewed',
      'feedback_viewed',
      'retry_started',
      'module_completed',
      'locale_changed'
    )
  ),
  stage text not null check (stage in ('briefing', 'receive', 'inspect', 'verify', 'decide', 'reveal', 'retry', 'complete')),
  metadata_json jsonb not null default '{}'::jsonb check (jsonb_typeof(metadata_json) = 'object'),
  occurred_at timestamptz not null default now()
);

create table public.user_module_progress (
  user_id uuid not null references auth.users (id) on delete cascade,
  module_id text not null check (module_id = 'courier-sms'),
  status text not null default 'not_started' check (status in ('not_started', 'in_progress', 'completed')),
  mastery_level text not null default 'not_started' check (mastery_level in ('not_started', 'familiar', 'skilled', 'needs_practice')),
  inspect_practised boolean not null default false,
  verify_practised boolean not null default false,
  report_practised boolean not null default false,
  last_practised_at timestamptz,
  primary key (user_id, module_id)
);

create table public.user_streaks (
  user_id uuid primary key references auth.users (id) on delete cascade,
  current_streak integer not null default 0 check (current_streak >= 0),
  longest_streak integer not null default 0 check (longest_streak >= 0),
  freezes_remaining integer not null default 1 check (freezes_remaining >= 0),
  last_qualifying_date date,
  updated_at timestamptz not null default now()
);

create table public.user_achievements (
  user_id uuid not null references auth.users (id) on delete cascade,
  code text not null check (char_length(code) between 1 and 64),
  awarded_at timestamptz not null default now(),
  primary key (user_id, code)
);

create index practice_attempts_user_completed_idx
  on public.practice_attempts (user_id, completed_at desc);

create index practice_events_attempt_occurred_idx
  on public.practice_events (attempt_id, occurred_at);

create index user_module_progress_user_idx
  on public.user_module_progress (user_id);

create index user_achievements_user_idx
  on public.user_achievements (user_id);

alter table public.profiles enable row level security;
alter table public.practice_attempts enable row level security;
alter table public.practice_events enable row level security;
alter table public.user_module_progress enable row level security;
alter table public.user_streaks enable row level security;
alter table public.user_achievements enable row level security;

create policy "profiles_select_own" on public.profiles
  for select using ((select auth.uid()) = id);
create policy "profiles_insert_own" on public.profiles
  for insert with check ((select auth.uid()) = id);
create policy "profiles_update_own" on public.profiles
  for update using ((select auth.uid()) = id) with check ((select auth.uid()) = id);

create policy "practice_attempts_select_own" on public.practice_attempts
  for select using ((select auth.uid()) = user_id);
create policy "practice_attempts_insert_own" on public.practice_attempts
  for insert with check ((select auth.uid()) = user_id);
create policy "practice_attempts_update_own" on public.practice_attempts
  for update using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);

create policy "practice_events_select_own" on public.practice_events
  for select using (
    exists (
      select 1 from public.practice_attempts
      where practice_attempts.id = practice_events.attempt_id
        and practice_attempts.user_id = (select auth.uid())
    )
  );
create policy "practice_events_insert_own" on public.practice_events
  for insert with check (
    exists (
      select 1 from public.practice_attempts
      where practice_attempts.id = practice_events.attempt_id
        and practice_attempts.user_id = (select auth.uid())
    )
  );

create policy "user_module_progress_select_own" on public.user_module_progress
  for select using ((select auth.uid()) = user_id);
create policy "user_module_progress_insert_own" on public.user_module_progress
  for insert with check ((select auth.uid()) = user_id);
create policy "user_module_progress_update_own" on public.user_module_progress
  for update using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);

create policy "user_streaks_select_own" on public.user_streaks
  for select using ((select auth.uid()) = user_id);
create policy "user_streaks_insert_own" on public.user_streaks
  for insert with check ((select auth.uid()) = user_id);
create policy "user_streaks_update_own" on public.user_streaks
  for update using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);

create policy "user_achievements_select_own" on public.user_achievements
  for select using ((select auth.uid()) = user_id);
create policy "user_achievements_insert_own" on public.user_achievements
  for insert with check ((select auth.uid()) = user_id);
create policy "user_achievements_update_own" on public.user_achievements
  for update using ((select auth.uid()) = user_id) with check ((select auth.uid()) = user_id);
