-- Editable profile operations and a separate, database-verified admin session.

-- ---------------------------------------------------------------------------
-- Profile: username and display badge selection
-- ---------------------------------------------------------------------------

create or replace function public.change_username(requested_username text)
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  current_user_id uuid := (select auth.uid());
  normalized_username text := btrim(requested_username);
begin
  if current_user_id is null then
    raise exception 'AUTHENTICATION_REQUIRED' using errcode = '42501';
  end if;
  if char_length(normalized_username) not between 3 and 24
     or normalized_username !~ '^[A-Za-z0-9_]+$' then
    raise exception 'INVALID_USERNAME' using errcode = '22023';
  end if;
  if exists (
    select 1 from public.profiles
    where lower(username) = lower(normalized_username)
      and id <> current_user_id
  ) then
    raise exception 'USERNAME_TAKEN' using errcode = '23505';
  end if;

  perform set_config('alethia.profile_identity_update', 'on', true);
  update public.profiles
  set username = normalized_username
  where id = current_user_id;
  perform set_config('alethia.profile_identity_update', 'off', true);

  update auth.users
  set raw_user_meta_data = jsonb_set(
    coalesce(raw_user_meta_data, '{}'::jsonb),
    '{username}',
    to_jsonb(normalized_username),
    true
  )
  where id = current_user_id;

  return normalized_username;
end;
$$;

create table public.user_profile_badges (
  user_id uuid not null references public.profiles (id) on delete cascade,
  badge_code text not null,
  selected boolean not null default false,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (user_id, badge_code),
  constraint user_profile_badges_earned_check foreign key (user_id, badge_code)
    references public.user_achievements (user_id, code) on delete cascade
);

create or replace function public.prepare_profile_badge_selection()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  insert into public.user_profile_badges (user_id, badge_code, selected)
  values (new.user_id, new.code, false)
  on conflict (user_id, badge_code) do nothing;
  return null;
end;
$$;

create trigger user_achievements_prepare_profile_badge
  after insert on public.user_achievements
  for each row execute function public.prepare_profile_badge_selection();

insert into public.user_profile_badges (user_id, badge_code, selected)
select achievement.user_id, achievement.code, false
from public.user_achievements as achievement
on conflict (user_id, badge_code) do nothing;

create or replace function public.set_profile_badge(
  requested_badge_code text,
  requested_selected boolean
)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  current_user_id uuid := (select auth.uid());
begin
  if current_user_id is null then
    raise exception 'AUTHENTICATION_REQUIRED' using errcode = '42501';
  end if;
  if not exists (
    select 1 from public.user_achievements
    where user_id = current_user_id and code = requested_badge_code
  ) then
    raise exception 'BADGE_NOT_EARNED' using errcode = '22023';
  end if;

  insert into public.user_profile_badges (user_id, badge_code, selected, updated_at)
  values (current_user_id, requested_badge_code, requested_selected, now())
  on conflict (user_id, badge_code) do update
  set selected = excluded.selected, updated_at = now();
  return requested_selected;
end;
$$;

-- ---------------------------------------------------------------------------
-- Admin identity, rate-limited login, and isolated sessions
-- ---------------------------------------------------------------------------

create table public.admin_accounts (
  id uuid primary key default gen_random_uuid(),
  username text not null check (username ~ '^[A-Za-z0-9_]{3,24}$'),
  password_hash text not null,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  last_login_at timestamptz
);
create unique index admin_accounts_username_lower_unique on public.admin_accounts (lower(username));

-- Set once, when the launch credential is rotated to a generated value. Its
-- presence is what stops a re-applied migration from invalidating the live
-- password. See 20260926070000.
alter table public.admin_accounts
  add column if not exists rotated_at timestamptz;

create table public.admin_sessions (
  id uuid primary key default gen_random_uuid(),
  admin_id uuid not null references public.admin_accounts (id) on delete cascade,
  token_hash text not null unique,
  expires_at timestamptz not null,
  created_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now()
);
create index admin_sessions_token_expiry_idx on public.admin_sessions (token_hash, expires_at);

create table public.admin_login_attempts (
  identity_hash text primary key,
  attempted_at timestamptz not null default now()
);
create index admin_login_attempts_recent_idx on public.admin_login_attempts (attempted_at);

-- Launch account. The password is a random value generated at apply time and
-- printed once via NOTICE; only its bcrypt hash is ever stored. Nothing about
-- the credential lives in version control.
--
-- Two details matter for re-applicability:
--
--   * There is deliberately NO `on conflict do update set password_hash`.
--     Re-running this file must never reset the password of a live account.
--   * rotated_at is set to NULL here, not now(). It is the flag 20260926070000
--     checks before performing the one-time rotation off the old launch
--     credential. Marking it here would tell that migration the rotation had
--     already happened and skip it, leaving the pre-rotation hash in place.
--
-- On a fresh database 20260926070000 will replace this password with another
-- generated one, also printed once. The two NOTICEs are not a mistake: apply the
-- chain in order and capture the final one.
do $$
declare
  launch_password text;
begin
  launch_password := encode(extensions.gen_random_bytes(18), 'base64');

  insert into public.admin_accounts (username, password_hash)
  values ('Alethia', extensions.crypt(launch_password, extensions.gen_salt('bf', 12)))
  on conflict ((lower(username))) do nothing;

  raise notice
    'Admin account seeded. username=Alethia password=%  Capture it now; it is not recoverable.',
    launch_password;
end;
$$;

create or replace function public.admin_login(
  requested_username text,
  requested_password text,
  request_ip text default ''
)
returns table (token text, username text, expires_at timestamptz)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  account_row public.admin_accounts%rowtype;
  identity_key text := encode(extensions.digest(lower(btrim(requested_username)) || ':' || coalesce(request_ip, ''), 'sha256'), 'hex');
  raw_token text;
begin
  if (
    select count(*) from public.admin_login_attempts
    where identity_hash = identity_key
      and attempted_at > now() - interval '15 minutes'
  ) >= 5 then
    raise exception 'ADMIN_LOGIN_RATE_LIMITED' using errcode = 'P0001';
  end if;

  insert into public.admin_login_attempts (identity_hash, attempted_at)
  values (identity_key, now())
  on conflict (identity_hash) do update set attempted_at = now();

  select * into account_row
  from public.admin_accounts
  where lower(username) = lower(btrim(requested_username))
    and is_active = true
    and password_hash = extensions.crypt(requested_password, password_hash)
  limit 1;

  if not found then
    raise exception 'INVALID_ADMIN_CREDENTIALS' using errcode = 'P0001';
  end if;

  delete from public.admin_login_attempts where identity_hash = identity_key;
  delete from public.admin_sessions where expires_at <= now();
  raw_token := encode(extensions.gen_random_bytes(32), 'hex');
  expires_at := now() + interval '8 hours';

  insert into public.admin_sessions (admin_id, token_hash, expires_at)
  values (account_row.id, encode(extensions.digest(raw_token, 'sha256'), 'hex'), expires_at);
  update public.admin_accounts set last_login_at = now() where id = account_row.id;

  return query select raw_token, account_row.username, expires_at;
end;
$$;

create or replace function public.admin_session_info(requested_token text)
returns table (username text, expires_at timestamptz)
language sql
security definer
set search_path = public, pg_temp
as $$
  select account.username, session.expires_at
  from public.admin_sessions as session
  join public.admin_accounts as account on account.id = session.admin_id
  where session.token_hash = encode(extensions.digest(requested_token, 'sha256'), 'hex')
    and session.expires_at > now()
    and account.is_active = true
  limit 1;
$$;

create or replace function public.admin_logout(requested_token text)
returns boolean
language sql
security definer
set search_path = public, pg_temp
as $$
  delete from public.admin_sessions
  where token_hash = encode(extensions.digest(requested_token, 'sha256'), 'hex')
  returning true;
$$;

create or replace function public.admin_list_reports(requested_token text)
returns table (
  id uuid, title text, author_username text, category text, channel text,
  pattern text, evidence text, why_risky text, defanged_url text,
  status text, review_status text, signal_score integer, created_at timestamptz
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
  select report.id, report.title, report.author_username, report.category,
    report.channel, report.pattern, report.evidence, report.why_risky,
    report.defanged_url, report.status, report.review_status, report.signal_score,
    report.created_at
  from public.practice_reports as report
  order by report.created_at desc;
end;
$$;

create or replace function public.admin_update_report(
  requested_token text,
  requested_report_id uuid,
  requested_status text,
  requested_review_status text
)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not exists (select 1 from public.admin_session_info(requested_token)) then
    raise exception 'ADMIN_SESSION_REQUIRED' using errcode = '42501';
  end if;
  if requested_status not in ('Queued for developer review', 'Triaged', 'Learning note')
     or requested_review_status not in ('queued', 'approved', 'rejected') then
    raise exception 'INVALID_REPORT_STATUS' using errcode = '22023';
  end if;

  perform set_config('alethia.admin_action', 'on', true);
  update public.practice_reports
  set status = requested_status,
      review_status = requested_review_status,
      reviewed_at = case when requested_review_status = 'queued' then null else now() end
  where id = requested_report_id;
  perform set_config('alethia.admin_action', 'off', true);
  return found;
end;
$$;

create or replace function public.admin_upsert_module(
  requested_token text,
  module_id text, module_content_key text, module_title_id text,
  module_description_id text, module_category text, module_route text,
  module_image_path text, module_difficulty smallint,
  module_position smallint, module_is_active boolean, module_is_published boolean
)
returns uuid
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  resolved_key text := nullif(btrim(module_content_key), '');
  resolved_published boolean := coalesce(module_is_published, false);
begin
  if not exists (select 1 from public.admin_session_info(requested_token)) then
    raise exception 'ADMIN_SESSION_REQUIRED' using errcode = '42501';
  end if;
  if resolved_published and resolved_key is null then
    raise exception 'PUBLISHED_MODULE_REQUIRES_CONTENT' using errcode = '22023';
  end if;

  insert into public.modules as module (
    id, content_key, title_id, title_en, description_id, description_en,
    category, route, image_path, difficulty, position, is_active, is_published
  ) values (
    btrim(module_id), resolved_key, btrim(module_title_id), btrim(module_title_id),
    btrim(module_description_id), btrim(module_description_id), btrim(module_category),
    btrim(module_route), nullif(btrim(coalesce(module_image_path, '')), ''), module_difficulty,
    module_position, coalesce(module_is_active, true), resolved_published
  )
  on conflict (id) do update set
    content_key = excluded.content_key, title_id = excluded.title_id,
    title_en = excluded.title_en, description_id = excluded.description_id,
    description_en = excluded.description_en, category = excluded.category,
    route = excluded.route, image_path = excluded.image_path,
    difficulty = excluded.difficulty, position = excluded.position,
    is_active = excluded.is_active, is_published = excluded.is_published,
    updated_at = now()
  returning module.id into module_id;
  return module_id;
end;
$$;

create or replace function public.admin_upsert_quest(
  requested_token text, quest_id text, quest_title text, quest_description text,
  quest_type text, target_value smallint, reward_points integer,
  quest_position smallint, quest_is_active boolean
)
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not exists (select 1 from public.admin_session_info(requested_token)) then
    raise exception 'ADMIN_SESSION_REQUIRED' using errcode = '42501';
  end if;
  insert into public.daily_quests as quest (
    id, title, description, quest_type, target_value, reward_points, position, is_active
  ) values (
    btrim(quest_id), btrim(quest_title), btrim(quest_description), quest_type,
    target_value, reward_points, quest_position, coalesce(quest_is_active, true)
  )
  on conflict (id) do update set
    title = excluded.title, description = excluded.description,
    quest_type = excluded.quest_type, target_value = excluded.target_value,
    reward_points = excluded.reward_points, position = excluded.position,
    is_active = excluded.is_active, updated_at = now();
  return quest_id;
end;
$$;

create or replace function public.admin_list_modules(requested_token text)
returns table (
  id text, content_key text, title_id text, description_id text, category text,
  route text, image_path text, difficulty smallint, module_position smallint,
  is_active boolean, is_published boolean
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not exists (select 1 from public.admin_session_info(requested_token)) then
    raise exception 'ADMIN_SESSION_REQUIRED' using errcode = '42501';
  end if;
  return query select module.id, module.content_key, module.title_id,
    module.description_id, module.category, module.route, module.image_path,
    module.difficulty, module.position as module_position, module.is_active, module.is_published
  from public.modules as module order by module.position, module.id;
end;
$$;

create or replace function public.admin_list_quests(requested_token text)
returns table (
  id text, title text, description text, quest_type text,
  target_value smallint, reward_points integer, quest_position smallint, is_active boolean
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  if not exists (select 1 from public.admin_session_info(requested_token)) then
    raise exception 'ADMIN_SESSION_REQUIRED' using errcode = '42501';
  end if;
  return query select quest.id, quest.title, quest.description, quest.quest_type,
    quest.target_value, quest.reward_points, quest.position as quest_position, quest.is_active
  from public.daily_quests as quest order by quest.position, quest.id;
end;
$$;

-- Allow the trusted admin function to change report moderation fields.
create or replace function public.protect_practice_report_system_fields()
returns trigger
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
begin
  if current_setting('alethia.admin_action', true) is distinct from 'on'
     and (new.id is distinct from old.id
       or new.user_id is distinct from old.user_id
       or new.author_username is distinct from old.author_username
       or new.source is distinct from old.source
       or new.signal_score is distinct from old.signal_score
       or new.review_status is distinct from old.review_status
       or new.status is distinct from old.status
       or new.reviewed_by is distinct from old.reviewed_by
       or new.reviewed_at is distinct from old.reviewed_at
       or new.created_at is distinct from old.created_at) then
    raise exception 'PRACTICE_REPORT_SYSTEM_FIELDS_IMMUTABLE' using errcode = '42501';
  end if;
  new.updated_at = now();
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- Locks and grants
-- ---------------------------------------------------------------------------

alter table public.user_profile_badges enable row level security;
alter table public.admin_accounts enable row level security;
alter table public.admin_sessions enable row level security;
alter table public.admin_login_attempts enable row level security;

create policy user_profile_badges_select_own on public.user_profile_badges
  for select to authenticated using (user_id = (select auth.uid()));

revoke all on table public.user_profile_badges from anon;
revoke insert, delete on table public.user_profile_badges from authenticated;
grant select on table public.user_profile_badges to authenticated;

revoke all on table public.admin_accounts, public.admin_sessions, public.admin_login_attempts from anon, authenticated, service_role;

revoke all on function public.change_username(text) from public;
grant execute on function public.change_username(text) to authenticated;
revoke all on function public.set_profile_badge(text, boolean) from public;
grant execute on function public.set_profile_badge(text, boolean) to authenticated;
revoke all on function public.prepare_profile_badge_selection() from public;

revoke all on function public.admin_login(text, text, text) from public;
grant execute on function public.admin_login(text, text, text) to anon;
revoke all on function public.admin_session_info(text) from public;
grant execute on function public.admin_session_info(text) to anon;
revoke all on function public.admin_logout(text) from public;
grant execute on function public.admin_logout(text) to anon;
revoke all on function public.admin_list_reports(text) from public;
grant execute on function public.admin_list_reports(text) to anon;
revoke all on function public.admin_update_report(text, uuid, text, text) from public;
grant execute on function public.admin_update_report(text, uuid, text, text) to anon;
revoke all on function public.admin_upsert_module(text, text, text, text, text, text, text, text, smallint, smallint, boolean, boolean) from public;
grant execute on function public.admin_upsert_module(text, text, text, text, text, text, text, text, smallint, smallint, boolean, boolean) to anon;
revoke all on function public.admin_upsert_quest(text, text, text, text, text, smallint, integer, smallint, boolean) from public;
grant execute on function public.admin_upsert_quest(text, text, text, text, text, smallint, integer, smallint, boolean) to anon;
revoke all on function public.admin_list_modules(text) from public;
grant execute on function public.admin_list_modules(text) to anon;
revoke all on function public.admin_list_quests(text) from public;
grant execute on function public.admin_list_quests(text) to anon;
