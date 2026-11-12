-- Fix PL/pgSQL ambiguity and correct admin module return type.

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
    select count(*) from public.admin_login_attempts as attempt
    where attempt.identity_hash = identity_key
      and attempt.attempted_at > now() - interval '15 minutes'
  ) >= 5 then
    raise exception 'ADMIN_LOGIN_RATE_LIMITED' using errcode = 'P0001';
  end if;

  insert into public.admin_login_attempts (identity_hash, attempted_at)
  values (identity_key, now())
  on conflict (identity_hash) do update set attempted_at = now();

  select account.* into account_row
  from public.admin_accounts as account
  where lower(account.username) = lower(btrim(requested_username))
    and account.is_active = true
    and account.password_hash = extensions.crypt(requested_password, account.password_hash)
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

drop function if exists public.admin_upsert_module(text, text, text, text, text, text, text, text, smallint, smallint, boolean, boolean);

create function public.admin_upsert_module(
  requested_token text,
  module_id text, module_content_key text, module_title_id text,
  module_description_id text, module_category text, module_route text,
  module_image_path text, module_difficulty smallint,
  module_position smallint, module_is_active boolean, module_is_published boolean
)
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  resolved_key text := nullif(btrim(module_content_key), '');
  resolved_published boolean := coalesce(module_is_published, false);
  resolved_module_id text;
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
  returning module.id into resolved_module_id;
  return resolved_module_id;
end;
$$;

revoke all on function public.admin_login(text, text, text) from public;
grant execute on function public.admin_login(text, text, text) to anon;
revoke all on function public.admin_upsert_module(text, text, text, text, text, text, text, text, smallint, smallint, boolean, boolean) from public;
grant execute on function public.admin_upsert_module(text, text, text, text, text, text, text, text, smallint, smallint, boolean, boolean) to anon;
