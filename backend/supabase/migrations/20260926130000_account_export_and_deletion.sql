-- Account export and deletion.
--
-- Both are rights, not features: PDP Law in Indonesia and GDPR Article 17 and
-- 20 both cover them, and an app collecting submitted reports, URLs and
-- evidence without either is a liability.
--
-- The deletion decision, stated so it can be argued with later:
--
--   Removed: the profile, points, quests, notifications, streaks, badges, signals
--            the user gave, investigation notes, and the authentication record.
--   Kept:    the user's reports, with user_id nulled and the author shown as
--            "Anonim".
--
-- An approved report is content the community has already read and learned
-- from. Deleting it takes something away from other people to satisfy a right
-- that is about the requester's own data, and a defanged URL plus a title is
-- not identifying once the account behind it is gone. The evidence text, the
-- screenshot and the URL are removed, because those are the parts that could
-- identify someone else or carry content that was not the author's to keep.
--
-- Ordering matters here. practice_reports.user_id is ON DELETE CASCADE, so
-- deleting the profile before anonymising would take the reports with it and
-- silently turn "anonymise" into "delete". The reports are detached first.

-- ---------------------------------------------------------------------------
-- 1. Reports can outlive their author
-- ---------------------------------------------------------------------------

-- The foreign key stays, including the cascade: a report that still has an
-- owner should still go if that owner is removed by any other route. Nulling
-- the column is what detaches a specific report.
alter table public.practice_reports
  alter column user_id drop not null;

comment on column public.practice_reports.user_id is
  'Null once the author has deleted their account. The report survives as community content with author_username set to Anonim.';

-- ---------------------------------------------------------------------------
-- 2. Export
-- ---------------------------------------------------------------------------

-- Everything held about the caller, in one document. Resolved from auth.uid()
-- with no parameter, so a caller cannot ask for someone else's data by passing
-- an id: there is no argument to pass one in.
create function public.export_my_data()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  caller_id uuid := (select auth.uid());
  exported_at timestamptz := now();
begin
  if caller_id is null then
    raise exception 'AUTHENTICATION_REQUIRED' using errcode = '42501';
  end if;

  return jsonb_build_object(
    'exported_at', exported_at,
    'account', (
      select to_jsonb(profile) - 'id'
      from public.profiles as profile
      where profile.id = caller_id
    ),
    'reports', coalesce((
      select jsonb_agg(to_jsonb(report) order by report.created_at)
      from public.practice_reports as report
      where report.user_id = caller_id
    ), '[]'::jsonb),
    'report_signals_given', coalesce((
      select jsonb_agg(to_jsonb(signal))
      from public.report_signals as signal
      where signal.user_id = caller_id
    ), '[]'::jsonb),
    'investigation_notes', coalesce((
      select jsonb_agg(to_jsonb(note))
      from public.report_investigation_notes as note
      where note.user_id = caller_id
    ), '[]'::jsonb),
    'point_ledger', coalesce((
      select jsonb_agg(to_jsonb(entry) order by entry.created_at)
      from public.user_point_ledger as entry
      where entry.user_id = caller_id
    ), '[]'::jsonb),
    'module_progress', coalesce((
      select jsonb_agg(to_jsonb(progress))
      from public.user_module_progress as progress
      where progress.user_id = caller_id
    ), '[]'::jsonb),
    'achievements', coalesce((
      select jsonb_agg(to_jsonb(achievement))
      from public.user_achievements as achievement
      where achievement.user_id = caller_id
    ), '[]'::jsonb),
    'badges', coalesce((
      select jsonb_agg(to_jsonb(badge))
      from public.user_profile_badges as badge
      where badge.user_id = caller_id
    ), '[]'::jsonb),
    'practice_streak', (
      select to_jsonb(streak)
      from public.user_streaks as streak
      where streak.user_id = caller_id
    ),
    'daily_streak', (
      select to_jsonb(streak)
      from public.user_daily_streaks as streak
      where streak.user_id = caller_id
    ),
    'daily_quests', coalesce((
      select jsonb_agg(to_jsonb(quest))
      from public.user_daily_quests as quest
      where quest.user_id = caller_id
    ), '[]'::jsonb),
    'notifications', coalesce((
      select jsonb_agg(to_jsonb(notification) order by notification.created_at)
      from public.notifications as notification
      where notification.user_id = caller_id
    ), '[]'::jsonb),
    'practice_attempts', coalesce((
      select jsonb_agg(to_jsonb(attempt))
      from public.practice_attempts as attempt
      where attempt.user_id = caller_id
    ), '[]'::jsonb),
    -- practice_events has no user_id of its own; it hangs off an attempt, so it
    -- is reached through practice_attempts. Filtering it directly would have been
    -- a compile-time-clean runtime error.
    'practice_events', coalesce((
      select jsonb_agg(to_jsonb(event) order by event.occurred_at)
      from public.practice_events as event
      join public.practice_attempts as attempt on attempt.id = event.attempt_id
      where attempt.user_id = caller_id
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function public.export_my_data() from public, anon;
grant execute on function public.export_my_data() to authenticated;

comment on function public.export_my_data() is
  'Everything held about the caller as one jsonb document. Takes no argument by design, so there is no id to pass and no way to export another account.';

-- ---------------------------------------------------------------------------
-- 3. Deletion
-- ---------------------------------------------------------------------------

create function public.delete_my_account(requested_confirm text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  caller_id uuid := (select auth.uid());
  confirm_text text;
  removed jsonb;
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

  perform set_config('alethia.admin_action', 'off', true);

  -- 2. Count what is about to go, for the summary the caller is shown. Taken
  --    before the deletes, because afterwards the rows no longer exist.
  select jsonb_build_object(
    'reports_anonymised', (
      select count(*)::integer from public.practice_reports as report
      where report.user_id = caller_id
    ),
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

revoke all on function public.delete_my_account(text) from public, anon;
grant execute on function public.delete_my_account(text) to authenticated;

comment on function public.delete_my_account(text) is
  'Removes the caller''s personal data and anonymises their reports. Requires the literal HAPUS AKUN SAYA. Irreversible.';

-- The export path is read-only, so it must not be reachable before sign-in.
-- grant execute to authenticated already implies that, but the anon revoke is
-- what stops a guess from a logged-out visitor.
revoke all on function public.export_my_data() from anon;
revoke all on function public.delete_my_account(text) from anon;
