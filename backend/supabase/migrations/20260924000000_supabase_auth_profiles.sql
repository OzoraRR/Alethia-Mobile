-- Supabase Auth identity and Alethia profile data.
-- auth.users remains the source of truth for credentials; this migration adds the
-- public profile projection and the small set of dashboard statistics used by the UI.

create extension if not exists pgcrypto;

-- Keep the identity fields explicit in this migration as well as compatible
-- with the earlier Sprint 1 progress migration.
create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  display_name text,
  preferred_locale text not null default 'id' check (preferred_locale in ('id', 'en')),
  email text,
  username text,
  created_at timestamptz not null default now(),
  mastery text not null default 'not_started',
  modules_completed integer not null default 0,
  current_streak integer not null default 0,
  longest_streak integer not null default 0,
  freezes_remaining integer not null default 1,
  badges text[] not null default '{}'::text[]
);

grant select, insert, update on public.profiles to authenticated;

alter table public.profiles
  add column if not exists email text,
  add column if not exists username text,
  add column if not exists created_at timestamptz,
  add column if not exists mastery text not null default 'not_started',
  add column if not exists modules_completed integer not null default 0,
  add column if not exists current_streak integer not null default 0,
  add column if not exists longest_streak integer not null default 0,
  add column if not exists freezes_remaining integer not null default 1,
  add column if not exists badges text[] not null default '{}'::text[];

-- The first progress migration created created_at already on fresh projects.
-- Fill it here as a defensive no-op for older/partial databases.
update public.profiles
set created_at = coalesce(created_at, now())
where created_at is null;

-- Backfill identity fields for profiles created by anonymous auth before this
-- migration. The UUID suffix makes the generated fallback username unique.
update public.profiles as profile
set email = auth_user.email
from auth.users as auth_user
where profile.id = auth_user.id
  and profile.email is null;

update public.profiles as profile
set username = left(
  regexp_replace(
    lower(coalesce(nullif(profile.username, ''), nullif(profile.display_name, ''), split_part(profile.email, '@', 1), 'operator')),
    '[^a-z0-9_]',
    '_',
    'g'
  ),
  15
) || '_' || substr(replace(profile.id::text, '-', ''), 1, 8)
where profile.username is null or btrim(profile.username) = '';

-- Also create projections for auth users that predate the profile migration.
insert into public.profiles (id, email, username, preferred_locale)
select
  auth_user.id,
  auth_user.email,
  left(
    regexp_replace(
      lower(split_part(coalesce(auth_user.email, auth_user.id::text), '@', 1)),
      '[^a-z0-9_]',
      '_',
      'g'
    ),
    7
  ) || '_' || substr(replace(auth_user.id::text, '-', ''), 1, 16),
  case
    when auth_user.raw_user_meta_data ->> 'preferred_locale' in ('id', 'en')
      then auth_user.raw_user_meta_data ->> 'preferred_locale'
    else 'id'
  end
from auth.users as auth_user
where not exists (
  select 1
  from public.profiles as existing_profile
  where existing_profile.id = auth_user.id
);

-- Normalize legacy values before adding the format and uniqueness guarantees.
update public.profiles
set username = 'operator_' || substr(replace(id::text, '-', ''), 1, 15)
where username is not null
  and (
    char_length(username) < 3
    or char_length(username) > 24
    or username !~ '^[A-Za-z0-9_]+$'
  );

with ranked as (
  select
    id,
    row_number() over (partition by lower(username) order by created_at, id) as duplicate_rank
  from public.profiles
  where username is not null
)
update public.profiles as profile
set username = left(profile.username, 7) || '_' || substr(replace(profile.id::text, '-', ''), 1, 16)
from ranked
where ranked.id = profile.id
  and ranked.duplicate_rank > 1;

-- Every auth profile, including an anonymous profile, receives a generated
-- username in the backfill/trigger above.
alter table public.profiles alter column username set not null;

-- Carry forward statistics created by the earlier Sprint 1 tables for users
-- who already have progress rows.
update public.profiles as profile
set mastery = coalesce(
      (
        select progress.mastery_level
        from public.user_module_progress as progress
        where progress.user_id = profile.id
          and progress.module_id = 'courier-sms'
        limit 1
      ),
      profile.mastery
    ),
    modules_completed = greatest(
      profile.modules_completed,
      (
        select count(*)::integer
        from public.user_module_progress as progress
        where progress.user_id = profile.id
          and progress.status = 'completed'
      )
    ),
    current_streak = coalesce(
      (select streak.current_streak from public.user_streaks as streak where streak.user_id = profile.id),
      profile.current_streak
    ),
    longest_streak = coalesce(
      (select streak.longest_streak from public.user_streaks as streak where streak.user_id = profile.id),
      profile.longest_streak
    ),
    freezes_remaining = coalesce(
      (select streak.freezes_remaining from public.user_streaks as streak where streak.user_id = profile.id),
      profile.freezes_remaining
    ),
    badges = coalesce(
      (
        select array_agg(achievement.code order by achievement.awarded_at)
        from public.user_achievements as achievement
        where achievement.user_id = profile.id
      ),
      profile.badges
    );

-- Keep the public identity fields well-formed. Anonymous profiles may have a
-- null email, but their username is always generated.
do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'profiles_username_format_check'
      and conrelid = 'public.profiles'::regclass
  ) then
    alter table public.profiles
      add constraint profiles_username_format_check
      check (
        username is null
        or (
          char_length(username) between 3 and 24
          and username ~ '^[A-Za-z0-9_]+$'
        )
      );
  end if;

  if not exists (
    select 1
    from pg_constraint
    where conname = 'profiles_mastery_check'
      and conrelid = 'public.profiles'::regclass
  ) then
    alter table public.profiles
      add constraint profiles_mastery_check
      check (mastery in ('not_started', 'familiar', 'skilled', 'needs_practice'));
  end if;

  if not exists (
    select 1
    from pg_constraint
    where conname = 'profiles_modules_completed_check'
      and conrelid = 'public.profiles'::regclass
  ) then
    alter table public.profiles
      add constraint profiles_modules_completed_check
      check (modules_completed between 0 and 3);
  end if;

  if not exists (
    select 1
    from pg_constraint
    where conname = 'profiles_current_streak_check'
      and conrelid = 'public.profiles'::regclass
  ) then
    alter table public.profiles
      add constraint profiles_current_streak_check
      check (current_streak >= 0);
  end if;

  if not exists (
    select 1
    from pg_constraint
    where conname = 'profiles_longest_streak_check'
      and conrelid = 'public.profiles'::regclass
  ) then
    alter table public.profiles
      add constraint profiles_longest_streak_check
      check (longest_streak >= 0);
  end if;

  if not exists (
    select 1
    from pg_constraint
    where conname = 'profiles_freezes_remaining_check'
      and conrelid = 'public.profiles'::regclass
  ) then
    alter table public.profiles
      add constraint profiles_freezes_remaining_check
      check (freezes_remaining between 0 and 1);
  end if;
end $$;

-- Case-insensitive uniqueness prevents Operator and operator from being two
-- different accounts while allowing the nullable email of an anonymous user.
create unique index if not exists profiles_username_lower_unique
  on public.profiles (lower(username))
  where username is not null;

create unique index if not exists profiles_email_lower_unique
  on public.profiles (lower(email))
  where email is not null;

-- Keep the profile row in sync whenever an auth user is created. The trigger is
-- deliberately security-definer because it runs inside the auth schema and
-- needs to insert the corresponding public profile.
create or replace function public.handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  requested_username text;
  candidate_username text;
  violated_constraint text;
begin
  requested_username := btrim(coalesce(new.raw_user_meta_data ->> 'username', ''));

  if requested_username <> '' then
    if char_length(requested_username) < 3
       or char_length(requested_username) > 24
       or requested_username !~ '^[A-Za-z0-9_]+$' then
      raise exception 'INVALID_USERNAME' using errcode = '22023';
    end if;
    candidate_username := requested_username;
  else
    -- Anonymous users do not provide an email/username. Derive a safe,
    -- deterministic fallback from the auth UUID.
    candidate_username := left(
      regexp_replace(lower(split_part(coalesce(new.email, new.id::text), '@', 1)), '[^a-z0-9_]', '_', 'g'),
      15
    ) || '_' || substr(replace(new.id::text, '-', ''), 1, 8);
  end if;

  begin
    insert into public.profiles (id, email, username, preferred_locale)
    values (
      new.id,
      lower(new.email),
      candidate_username,
      case
        when new.raw_user_meta_data ->> 'preferred_locale' in ('id', 'en')
          then new.raw_user_meta_data ->> 'preferred_locale'
        else 'id'
      end
    );
  exception
    when unique_violation then
      get stacked diagnostics violated_constraint = CONSTRAINT_NAME;
      if violated_constraint = 'profiles_username_lower_unique'
         or violated_constraint like '%username%unique%' then
        raise exception 'USERNAME_TAKEN' using errcode = '23505';
      elsif violated_constraint = 'profiles_email_lower_unique'
         or violated_constraint like '%email%unique%' then
        raise exception 'EMAIL_TAKEN' using errcode = '23505';
      else
        raise;
      end if;
  end;

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row
  execute function public.handle_new_auth_user();

-- Keep the public identity projection immutable from the browser. Progress,
-- streak, badge, locale, and avatar fields remain user-updatable through the
-- normal RLS policy.
create or replace function public.protect_profile_identity()
returns trigger
language plpgsql
as $$
begin
  if current_setting('alethia.profile_identity_update', true) is distinct from 'on'
     and coalesce(auth.role(), current_user) in ('anon', 'authenticated')
     and (
       new.id is distinct from old.id
       or new.email is distinct from old.email
       or new.username is distinct from old.username
     ) then
    raise exception 'PROFILE_IDENTITY_IMMUTABLE' using errcode = '42501';
  end if;
  return new;
end;
$$;

drop trigger if exists profiles_identity_immutable on public.profiles;
create trigger profiles_identity_immutable
  before update on public.profiles
  for each row
  execute function public.protect_profile_identity();

-- Email changes made through Supabase Auth are reflected in the projection.
create or replace function public.handle_auth_user_update()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if new.email is distinct from old.email then
    perform set_config('alethia.profile_identity_update', 'on', true);
    update public.profiles
    set email = lower(new.email)
    where id = new.id;
    perform set_config('alethia.profile_identity_update', 'off', true);
  end if;
  return new;
end;
$$;

drop trigger if exists on_auth_user_updated on auth.users;
create trigger on_auth_user_updated
  after update of email on auth.users
  for each row
  execute function public.handle_auth_user_update();

-- Login accepts a username, while Supabase Auth signs in with an email. These
-- narrowly-scoped SECURITY DEFINER functions avoid exposing every profile row
-- to unauthenticated visitors while still allowing the username lookup.
create or replace function public.profile_username_exists(requested_username text)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
    from public.profiles
    where username is not null
      and lower(username) = lower(btrim(requested_username))
  );
$$;

create or replace function public.get_profile_email_by_username(requested_username text)
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select profile.email
  from public.profiles as profile
  where profile.username is not null
    and lower(profile.username) = lower(btrim(requested_username))
    and profile.email is not null
  limit 1;
$$;

revoke all on function public.profile_username_exists(text) from public;
revoke all on function public.get_profile_email_by_username(text) from public;
grant usage on schema public to anon, authenticated;
grant execute on function public.profile_username_exists(text) to authenticated;
grant execute on function public.get_profile_email_by_username(text) to anon, authenticated;

-- Profile rows are private to their owner. The trigger is the only path that
-- creates a row for a new auth user; clients may read and update their own
-- profile after authentication.
alter table public.profiles enable row level security;

drop policy if exists profiles_select_own on public.profiles;
drop policy if exists profiles_insert_own on public.profiles;
drop policy if exists profiles_update_own on public.profiles;

create policy "profiles_select_own" on public.profiles
  for select
  using ((select auth.uid()) = id);

create policy "profiles_insert_own" on public.profiles
  for insert
  with check ((select auth.uid()) = id);

create policy "profiles_update_own" on public.profiles
  for update
  using ((select auth.uid()) = id)
  with check ((select auth.uid()) = id);

comment on table public.profiles is
  'Public Alethia profile projection for auth.users, including dashboard progress statistics.';
comment on function public.handle_new_auth_user() is
  'Creates a public profile and applies Alethia identity defaults for each new Supabase auth user.';
