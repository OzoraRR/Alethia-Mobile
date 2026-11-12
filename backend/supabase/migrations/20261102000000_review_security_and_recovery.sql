-- Forward-only fixes for authorization, login limiting, data deletion and retry recovery.
-- Ordinary login failures return data so their attempt counter commits.
alter table public.admin_login_attempts
  add column failure_count integer not null default 0,
  add column window_started_at timestamptz not null default now();

drop function public.admin_login(text, text, text);
create function public.admin_login(requested_username text, requested_password text, request_ip text default '')
returns table (token text, username text, expires_at timestamptz, error_code text)
language plpgsql security definer set search_path = pg_catalog as $$
declare
  account_row public.admin_accounts;
  attempt_row public.admin_login_attempts;
  identity_key text := encode(extensions.digest(lower(btrim(coalesce(requested_username,''))), 'sha256'), 'hex');
  raw_token text;
begin
  -- Account-scoped: changing an untrusted forwarding header cannot evade this limit.
  -- Unknown names must not allocate unbounded counter rows.
  if not exists(select 1 from public.admin_accounts account
    where lower(account.username)=lower(btrim(requested_username)) and account.is_active) then
    return query select null::text, null::text, null::timestamptz, 'INVALID_ADMIN_CREDENTIALS'::text;
    return;
  end if;
  insert into public.admin_login_attempts(identity_hash) values(identity_key)
    on conflict (identity_hash) do nothing;
  select * into attempt_row from public.admin_login_attempts
    where identity_hash = identity_key for update;
  if attempt_row.window_started_at <= now() - interval '15 minutes' then
    update public.admin_login_attempts set failure_count = 0, window_started_at = now()
      where identity_hash = identity_key;
    attempt_row.failure_count := 0;
  end if;
  if attempt_row.failure_count >= 5 then
    return query select null::text, null::text, null::timestamptz, 'ADMIN_LOGIN_RATE_LIMITED'::text;
    return;
  end if;
  select account.* into account_row from public.admin_accounts account
    where lower(account.username) = lower(btrim(requested_username)) and account.is_active
      and account.password_hash = case when octet_length(requested_password) between 1 and 72
        then extensions.crypt(requested_password, account.password_hash) else null end;
  if not found then
    update public.admin_login_attempts set failure_count = failure_count + 1, attempted_at = now()
      where identity_hash = identity_key;
    return query select null::text, null::text, null::timestamptz, 'INVALID_ADMIN_CREDENTIALS'::text;
    return;
  end if;
  -- Retain the locked row so concurrent requests cannot race a deleted counter.
  update public.admin_login_attempts set failure_count = 0, window_started_at = now(), attempted_at = now()
    where identity_hash = identity_key;
  delete from public.admin_sessions session where session.expires_at <= now();
  raw_token := encode(extensions.gen_random_bytes(32), 'hex');
  insert into public.admin_sessions(admin_id,token_hash,expires_at)
    values(account_row.id,encode(extensions.digest(raw_token,'sha256'),'hex'),now()+interval '8 hours');
  update public.admin_accounts set last_login_at = now() where id = account_row.id;
  return query select raw_token, account_row.username, now()+interval '8 hours', null::text;
end;
$$;
revoke all on function public.admin_login(text,text,text) from public, anon, authenticated;
grant execute on function public.admin_login(text,text,text) to service_role;

-- Client inserts/updates may never manufacture the investigator cache.
create function public.guard_report_verdict_fields()
returns trigger language plpgsql security invoker set search_path = pg_catalog as $$
begin
  if current_user in ('anon','authenticated') then
    if (tg_op = 'INSERT' and (new.investigator_verdict is not null or new.verdict_by is not null or new.verdict_at is not null))
      or (tg_op = 'UPDATE' and (new.investigator_verdict is distinct from old.investigator_verdict
        or new.verdict_by is distinct from old.verdict_by or new.verdict_at is distinct from old.verdict_at)) then
      raise exception 'REPORT_VERDICT_REQUIRES_INVESTIGATOR_RPC' using errcode = '42501';
    end if;
  end if;
  return new;
end;
$$;
create trigger practice_reports_guard_verdict before insert or update on public.practice_reports
  for each row execute function public.guard_report_verdict_fields();
revoke all on function public.guard_report_verdict_fields() from public,anon,authenticated,service_role;

create function public.is_investigator()
returns boolean language sql stable security definer set search_path = pg_catalog as $$
  select (auth.jwt()->>'is_anonymous') = 'false' and (
    select count(*) >= 2 from public.user_module_progress p join public.modules m on m.id=p.module_id
    where p.user_id=auth.uid() and p.status='completed' and m.is_active and m.is_published and m.content_key is not null
  );
$$;
revoke all on function public.is_investigator() from public,anon,authenticated,service_role;
grant execute on function public.is_investigator() to authenticated;
create policy report_signals_require_investigator on public.report_signals
  as restrictive for insert to authenticated with check ((select public.is_investigator()));
create or replace function public.set_note_author()
returns trigger language plpgsql security definer set search_path = pg_catalog as $$
begin
  select p.username into new.author_username from public.profiles p where p.id=new.user_id;
  new.author_role := case when public.is_investigator() then 'investigator' else 'student' end;
  return new;
end;
$$;

-- Rebuild caches from actual votes; reject forged historical role labels too.
update public.practice_reports report set
  (investigator_verdict,verdict_by,verdict_at) = (
    select vote.verdict,vote.user_id,vote.updated_at from public.report_verdicts vote
    where vote.report_id=report.id order by vote.updated_at desc,vote.user_id desc limit 1
  );
update public.report_investigation_notes note set author_role = case when (
  select count(*) >= 2 from public.user_module_progress p join public.modules m on m.id=p.module_id
  where p.user_id=note.user_id and p.status='completed' and m.is_active and m.is_published and m.content_key is not null
) then 'investigator' else 'student' end;

-- Freeze new avatar writes before the server removes object bytes through Storage.
create table public.account_deletion_requests (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  requested_at timestamptz not null default now()
);
alter table public.account_deletion_requests enable row level security;
revoke all on public.account_deletion_requests from anon,authenticated,service_role;
create function public.account_accepts_avatar_uploads()
returns boolean language sql stable security definer set search_path = pg_catalog as $$
  select exists(select 1 from public.profiles where id=auth.uid())
    and not exists(select 1 from public.account_deletion_requests where user_id=auth.uid());
$$;
revoke all on function public.account_accepts_avatar_uploads() from public,anon,authenticated,service_role;
grant execute on function public.account_accepts_avatar_uploads() to authenticated;
create policy avatars_no_upload_during_deletion on storage.objects as restrictive for insert to authenticated
  with check (bucket_id <> 'avatars' or (select public.account_accepts_avatar_uploads()));
create policy avatars_no_update_during_deletion on storage.objects as restrictive for update to authenticated
  using (bucket_id <> 'avatars' or (select public.account_accepts_avatar_uploads()))
  with check (bucket_id <> 'avatars' or (select public.account_accepts_avatar_uploads()));
create function public.prepare_account_deletion(requested_confirm text)
returns text[] language plpgsql security definer set search_path = pg_catalog as $$
declare caller_id uuid := auth.uid(); paths text[];
begin
  perform public.require_permanent_account();
  if btrim(coalesce(requested_confirm,'')) <> 'HAPUS AKUN SAYA' then
    raise exception 'CONFIRMATION_REQUIRED' using errcode='22023';
  end if;
  perform 1 from public.profiles where id=caller_id for update;
  if not found then raise exception 'PROFILE_NOT_FOUND' using errcode='22023'; end if;
  insert into public.account_deletion_requests(user_id) values(caller_id) on conflict do nothing;
  select coalesce(array_agg(name),'{}') into paths from storage.objects
    where bucket_id='avatars' and name like caller_id::text || '/%';
  return paths;
end;
$$;
revoke all on function public.prepare_account_deletion(text) from public,anon,authenticated,service_role;
grant execute on function public.prepare_account_deletion(text) to authenticated;


create or replace function public._delete_my_account_before_permanent_guard(requested_confirm text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  caller_id uuid := (select auth.uid());
  confirm_text text;
  removed jsonb;
  anonymised_count integer;
begin
  if caller_id is null then
    raise exception 'AUTHENTICATION_REQUIRED' using errcode = '42501';
  end if;

  -- A typed confirmation, because this cannot be undone and there is no undo
  -- button in a database. The literal is checked here rather than trusted from
  -- the client, so a caller cannot pass an empty string and slip through.
  confirm_text := btrim(coalesce(requested_confirm, ''));
  if confirm_text <> 'HAPUS AKUN SAYA' then
    raise exception 'CONFIRMATION_REQUIRED' using errcode = '22023';
  end if;

  if not exists (select 1 from public.profiles as profile where profile.id = caller_id) then
    raise exception 'PROFILE_NOT_FOUND' using errcode = '22023';
  end if;

  if not exists(select 1 from public.account_deletion_requests where user_id=caller_id) then
    raise exception 'ACCOUNT_DELETION_REQUIRES_PREPARATION' using errcode='42501';
  end if;
  if exists(select 1 from storage.objects where bucket_id='avatars' and name like caller_id::text || '/%') then
    raise exception 'ACCOUNT_AVATARS_REMAIN' using errcode='23514';
  end if;

  -- 1. Detach the reports before anything is deleted. The guard trigger blocks
  --    user_id changes for anon and authenticated, and it is keyed on
  --    auth.role(), which still reads as authenticated inside a SECURITY DEFINER
  --    function. The same GUC every admin RPC uses is therefore needed here.
  perform set_config('alethia.admin_action', 'on', true);

  update public.practice_reports as report
  set user_id = null,
      author_username = 'Anonim',
      evidence = 'Withdrawn by the author.',
      why_risky = 'Withdrawn by the author.',
      defanged_url = null,
      screenshot_path = null,
      screenshot_data_url = null
  where report.user_id = caller_id;

  get diagnostics anonymised_count = row_count;
  perform set_config('alethia.admin_action', 'off', true);

  -- 2. Count what is about to go, for the summary the caller is shown. Taken
  --    before the deletes, because afterwards the rows no longer exist.
  select jsonb_build_object(
    'reports_anonymised', anonymised_count,
    'point_ledger_entries', (
      select count(*)::integer from public.user_point_ledger as entry
      where entry.user_id = caller_id
    ),
    'notifications', (
      select count(*)::integer from public.notifications as notification
      where notification.user_id = caller_id
    ),
    'achievements', (
      select count(*)::integer from public.user_achievements as achievement
      where achievement.user_id = caller_id
    )
  )
  into removed;

  -- 3. Deleting the profile cascades to everything that references it: points,
  --    quests, notifications, streaks, badges, signals, attempts, tombstones.
  delete from public.profiles where id = caller_id;

  -- 4. And the authentication record. auth.users owns auth.identities through a
  --    cascade, so this one statement removes the credentials as well. Doing it
  --    in SQL rather than through the Auth admin API is a deliberate trade: this
  --    app holds no service_role key, and the function resolves auth.uid() with
  --    no parameter, so it can only ever delete the caller's own account.
  delete from auth.users where id = caller_id;

  return removed || jsonb_build_object('account_deleted', true);
end;
$$;

-- Include records introduced after the original export implementation.
create or replace function public.export_my_data()
returns jsonb language plpgsql stable security definer set search_path = pg_catalog as $$
begin
  perform public.require_permanent_account();
  return public._export_my_data_before_permanent_guard() || jsonb_build_object(
    'report_verdicts', coalesce((select jsonb_agg(to_jsonb(v) order by v.created_at)
      from public.report_verdicts v where v.user_id=auth.uid()), '[]'::jsonb)
  );
end;
$$;

-- Serializing retries on the attempt lock makes response-loss recovery idempotent.
create or replace function public.complete_verified_practice_attempt(requested_attempt_id uuid, requested_decisions jsonb)
returns table(score smallint, perfect boolean, started_at timestamptz)
language plpgsql security definer set search_path = pg_catalog as $$
declare attempt_row public.practice_attempts; result_metadata jsonb;
begin
  perform public.require_permanent_account();
  select * into attempt_row from public.practice_attempts
    where id=requested_attempt_id and user_id=auth.uid() for update;
  if not found then raise exception 'ATTEMPT_NOT_FOUND' using errcode='42501'; end if;
  if attempt_row.completed_at is not null then
    select metadata_json into result_metadata from public.practice_events
      where attempt_id=requested_attempt_id and event_type='module_completed'
      order by occurred_at desc limit 1;
    if result_metadata is null then raise exception 'ATTEMPT_RESULT_UNAVAILABLE' using errcode='23514'; end if;
    return query select (result_metadata->>'score')::smallint,
      (result_metadata->>'perfect')::boolean, attempt_row.started_at;
    return;
  end if;
  return query select * from public._complete_verified_practice_attempt_before_permanent_guard(
    requested_attempt_id,requested_decisions);
end;
$$;
