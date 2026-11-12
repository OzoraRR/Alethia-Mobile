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
  if not found then raise exception 'INVALID_ADMIN_CREDENTIALS' using errcode = 'P0001'; end if;
  delete from public.admin_login_attempts where identity_hash = identity_key;
  delete from public.admin_sessions as session where session.expires_at <= now();
  raw_token := encode(extensions.gen_random_bytes(32), 'hex');
  expires_at := now() + interval '8 hours';
  insert into public.admin_sessions (admin_id, token_hash, expires_at)
  values (account_row.id, encode(extensions.digest(raw_token, 'sha256'), 'hex'), expires_at);
  update public.admin_accounts set last_login_at = now() where id = account_row.id;
  return query select raw_token, account_row.username, expires_at;
end;
$$;

revoke all on function public.admin_login(text, text, text) from public;
grant execute on function public.admin_login(text, text, text) to anon;
