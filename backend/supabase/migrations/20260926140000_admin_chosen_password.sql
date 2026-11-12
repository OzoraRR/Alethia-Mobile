-- Keep operator-selected credentials out of migrations and source control.
-- The default/admin bootstrap remains random until an owner chooses a value.
-- After this migration is applied, set one manually in the SQL editor with:
--   select public.admin_set_password('<operator-chosen-secret>');
-- Never commit the chosen value or pass it through a browser-facing RPC.

create or replace function public.admin_set_password(new_password text)
returns text
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  changed_id uuid;
begin
  if char_length(coalesce(new_password, '')) < 4 then
    raise exception 'ADMIN_PASSWORD_TOO_SHORT' using errcode = '22023';
  end if;

  update public.admin_accounts as account
  set password_hash = extensions.crypt(new_password, extensions.gen_salt('bf', 12)),
      rotated_at = now()
  where lower(account.username) = 'alethia'
  returning account.id into changed_id;

  if changed_id is null then
    raise exception 'ADMIN_ACCOUNT_NOT_FOUND' using errcode = 'P0002';
  end if;

  delete from public.admin_sessions as session
  where session.admin_id = changed_id;

  return 'ok';
end;
$$;

revoke all on function public.admin_set_password(text) from public, anon, authenticated;
comment on function public.admin_set_password(text) is
  'Owner-only manual password update. Takes a chosen secret; keep it out of browser clients and source control.';
