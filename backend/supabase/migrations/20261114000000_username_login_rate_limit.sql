-- Bound public username lookups before the private email-resolution RPC.
-- The API stores only a keyed HMAC of the client IP, never the raw address.
create table public.username_login_rate_limits (
  identity_hash text primary key
    check (identity_hash ~ '^[0-9a-f]{64}$'),
  attempt_count integer not null default 0
    check (attempt_count >= 0),
  window_started_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index username_login_rate_limits_updated_at_idx
  on public.username_login_rate_limits (updated_at);

alter table public.username_login_rate_limits enable row level security;
revoke all on table public.username_login_rate_limits
  from public, anon, authenticated, service_role;

create function public.consume_username_login_rate_limit(requested_identity_hash text)
returns table (allowed boolean, retry_after_seconds integer)
language plpgsql
security definer
set search_path = pg_catalog
as $$
declare
  attempt_row public.username_login_rate_limits;
  request_time timestamptz := now();
  limit_window interval := interval '15 minutes';
  max_attempts integer := 30;
begin
  if requested_identity_hash is null
    or requested_identity_hash !~ '^[0-9a-f]{64}$' then
    raise exception 'INVALID_USERNAME_LOGIN_RATE_LIMIT_IDENTITY'
      using errcode = '22023';
  end if;

  -- Lazily prune counters inactive for a day. The indexed predicate keeps
  -- cleanup bounded to expired rows as the table grows.
  delete from public.username_login_rate_limits
    where updated_at < request_time - interval '24 hours';

  insert into public.username_login_rate_limits(identity_hash, attempt_count, window_started_at, updated_at)
    values (requested_identity_hash, 0, request_time, request_time)
    on conflict (identity_hash) do nothing;

  select * into attempt_row
    from public.username_login_rate_limits
    where identity_hash = requested_identity_hash
    for update;

  if attempt_row.window_started_at <= request_time - limit_window then
    update public.username_login_rate_limits
      set attempt_count = 0,
          window_started_at = request_time,
          updated_at = request_time
      where identity_hash = requested_identity_hash;
    attempt_row.attempt_count := 0;
    attempt_row.window_started_at := request_time;
  end if;

  if attempt_row.attempt_count >= max_attempts then
    return query select
      false,
      greatest(
        1,
        ceil(extract(epoch from (attempt_row.window_started_at + limit_window - request_time)))::integer
      );
    return;
  end if;

  update public.username_login_rate_limits
    set attempt_count = attempt_count + 1,
        updated_at = request_time
    where identity_hash = requested_identity_hash;

  return query select true, 0;
end;
$$;

revoke all on function public.consume_username_login_rate_limit(text)
  from public, anon, authenticated;
grant execute on function public.consume_username_login_rate_limit(text)
  to service_role;

comment on table public.username_login_rate_limits is
  'Short-lived HMAC identifiers and counters for public username login throttling.';
