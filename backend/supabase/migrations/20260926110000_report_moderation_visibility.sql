-- Report moderation made visible to the author, and deletable by an admin.
--
-- Two problems this addresses:
--
--   1. The user-facing report hub only ever rendered a binary "queued or not".
--      review_status was already selected and RLS already allowed reading it, so
--      approved and rejected reports were on the wire and simply never drawn.
--      A rejected report looked identical to an approved one.
--
--   2. There was no way for an admin to remove a report. Everything cascaded
--      cleanly, but the moderation path had no delete at all.
--
-- On deletion semantics. The report row is really deleted: evidence, url,
-- screenshot and signal counts all go, and report_review_events cascades with
-- it. So the author needs a durable notice, or their report vanishes with no
-- explanation at all. report_deletions is that notice.
--
-- What the tombstone deliberately does NOT keep: evidence, defanged_url,
-- screenshot, channel, pattern, why_risky or signal_score. The author's own
-- title is retained because a notice that cannot name what it refers to is
-- useless, and the title is text the author wrote and can already see. If a
-- report is being removed because its content is illegal, note that the title
-- survives; the substance does not.

-- ---------------------------------------------------------------------------
-- 1. Deletion tombstones
-- ---------------------------------------------------------------------------

create table public.report_deletions (
  -- No foreign key to practice_reports: the row is gone by design, and a
  -- constraint here would make the notice depend on the thing it replaces.
  report_id uuid primary key,
  owner_id uuid not null references public.profiles (id) on delete cascade,
  author_title text not null check (char_length(btrim(author_title)) between 1 and 300),
  reason text not null check (char_length(btrim(reason)) between 4 and 1000),
  deleted_by text not null check (char_length(btrim(deleted_by)) between 1 and 64),
  deleted_at timestamptz not null default now()
);

comment on table public.report_deletions is
  'Durable notice that an admin deleted a report. Holds no report content beyond the author''s own title, so the author can see why their submission disappeared without the evidence, url or screenshot being retained.';

create index report_deletions_owner_idx
  on public.report_deletions (owner_id, deleted_at desc);

alter table public.report_deletions enable row level security;

-- Author reads their own notices. No insert, update or delete policy exists, so
-- there is no client write path: the only writer is admin_delete_reports below.
drop policy if exists report_deletions_select_own on public.report_deletions;
create policy report_deletions_select_own
  on public.report_deletions
  for select
  to authenticated
  using (owner_id = (select auth.uid()));

revoke all on public.report_deletions from anon;
grant select on public.report_deletions to authenticated;

-- ---------------------------------------------------------------------------
-- 2. Author-visible reviewer feedback
-- ---------------------------------------------------------------------------

-- Distinct from admin_note, which is moderation-internal and stays hidden.
alter table public.practice_reports
  add column if not exists reviewer_feedback text;

alter table public.practice_reports
  drop constraint if exists practice_reports_reviewer_feedback_check;
alter table public.practice_reports
  add constraint practice_reports_reviewer_feedback_check
  check (reviewer_feedback is null or char_length(btrim(reviewer_feedback)) between 4 and 2000);

comment on column public.practice_reports.reviewer_feedback is
  'Explanation shown to the report author. Written only by a verified admin when rejecting, cleared when the report is approved or re-queued.';

-- Without adding it to this list, an author could set their own rejection
-- reason, because the column would be an ordinary updatable field.
create or replace function public.protect_practice_report_system_fields()
returns trigger
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
begin
  if current_setting('alethia.admin_action', true) is distinct from 'on'
     and coalesce(auth.role(), current_user) in ('anon', 'authenticated')
     and (
       new.id is distinct from old.id
       or new.user_id is distinct from old.user_id
       or new.author_username is distinct from old.author_username
       or new.source is distinct from old.source
       or new.signal_score is distinct from old.signal_score
       or new.review_status is distinct from old.review_status
       or new.status is distinct from old.status
       or new.reviewed_by is distinct from old.reviewed_by
       or new.reviewed_at is distinct from old.reviewed_at
       or new.admin_note is distinct from old.admin_note
       or new.reviewer_feedback is distinct from old.reviewer_feedback
       or new.created_at is distinct from old.created_at
     ) then
    raise exception 'PRACTICE_REPORT_SYSTEM_FIELDS_IMMUTABLE' using errcode = '42501';
  end if;

  new.updated_at := now();
  return new;
end;
$$;

-- ---------------------------------------------------------------------------
-- 3. Review writer gains a feedback argument
-- ---------------------------------------------------------------------------

-- Dropped rather than replaced: create or replace cannot add a parameter, and
-- the old five-argument form would otherwise linger as a live entry point that
-- silently accepts no feedback.
drop function if exists public.apply_report_review(text, uuid[], text, text, text);

create function public.apply_report_review(
  requested_token text,
  requested_report_ids uuid[],
  requested_status text,
  requested_review_status text,
  requested_note text default null,
  requested_feedback text default null
)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  session_username text;
  target record;
  changed_ids uuid[] := '{}'::uuid[];
  change_count integer;
  -- Feedback is the rejection reason, so it is only meaningful while the report
  -- is rejected. Keeping a stale reason on a report that was later approved
  -- would show the author a contradiction.
  feedback_value text;
begin
  select account.username
  into session_username
  from public.admin_sessions as session
  join public.admin_accounts as account on account.id = session.admin_id
  where session.token_hash = encode(extensions.digest(requested_token, 'sha256'), 'hex')
    and session.expires_at > now()
    and account.is_active = true
  limit 1;

  if session_username is null then
    raise exception 'ADMIN_SESSION_REQUIRED' using errcode = '42501';
  end if;

  if requested_status not in ('Queued for developer review', 'Triaged', 'Learning note')
     or requested_review_status not in ('queued', 'approved', 'rejected') then
    raise exception 'INVALID_REPORT_STATUS' using errcode = '22023';
  end if;

  if requested_report_ids is null or array_length(requested_report_ids, 1) is null then
    raise exception 'REPORT_IDS_REQUIRED' using errcode = '22023';
  end if;

  if array_length(requested_report_ids, 1) > 500 then
    raise exception 'TOO_MANY_REPORT_IDS' using errcode = '22023';
  end if;

  feedback_value := nullif(btrim(coalesce(requested_feedback, '')), '');

  if requested_review_status = 'rejected' and feedback_value is null then
    -- Rejecting without saying why is the one outcome the author cannot act
    -- on, so it is refused rather than accepted silently.
    raise exception 'REVIEW_FEEDBACK_REQUIRED' using errcode = '22023';
  end if;

  if feedback_value is not null
     and char_length(feedback_value) not between 4 and 2000 then
    raise exception 'REVIEW_FEEDBACK_TOO_LONG' using errcode = '22023';
  end if;

  for target in
    select report.id, report.status, report.review_status
    from public.practice_reports as report
    where report.id = any (requested_report_ids)
    for update
  loop
    insert into public.report_review_events (
      report_id,
      actor_username,
      previous_status,
      previous_review_status,
      next_status,
      next_review_status,
      note
    )
    values (
      target.id,
      session_username,
      target.status,
      target.review_status,
      requested_status,
      requested_review_status,
      nullif(btrim(coalesce(requested_note, '')), '')
    );

    changed_ids := changed_ids || target.id;
  end loop;

  change_count := coalesce(array_length(changed_ids, 1), 0);

  if change_count > 0 then
    perform set_config('alethia.admin_action', 'on', true);
    update public.practice_reports as report
    set status = requested_status,
        review_status = requested_review_status,
        admin_note = nullif(btrim(coalesce(requested_note, '')), ''),
        reviewer_feedback = case
          when requested_review_status = 'rejected' then feedback_value
          else null
        end,
        -- practice_reports.reviewed_by is a uuid FK to public.profiles, NOT to
        -- admin_accounts, and an operator has no profiles row. It stays NULL;
        -- attribution comes from report_review_events.actor_username.
        reviewed_by = case
          when requested_review_status = 'queued' then null
          else report.reviewed_by
        end,
        reviewed_at = case
          when requested_review_status = 'queued' then null
          else coalesce(report.reviewed_at, now())
        end
    where report.id = any (changed_ids);
    perform set_config('alethia.admin_action', 'off', true);

    -- The audit row keeps the feedback even though the review event does not.
    -- The event note is moderation-internal; mixing the two would make the
    -- author-facing text readable in the internal history.
    perform public.write_admin_audit(
      requested_token,
      case
        when change_count = 1 then 'report.update'
        else 'report.bulk_update'
      end,
      'practice_reports',
      coalesce(changed_ids[1]::text, 'none'),
      jsonb_build_object(
        'report_ids', to_jsonb(changed_ids),
        'count', change_count,
        'status', requested_status,
        'review_status', requested_review_status,
        'reviewer_feedback', to_jsonb(feedback_value)
      )
    );
  end if;

  return change_count;
end;
$$;

revoke all on function public.apply_report_review(text, uuid[], text, text, text, text) from public;
grant execute on function public.apply_report_review(text, uuid[], text, text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- 4. Admin deletion
-- ---------------------------------------------------------------------------

-- Array input for the same reason apply_report_review takes an array: one
-- implementation serves the single-button and bulk-selection paths, so the
-- tombstone, the cascade and the audit entry cannot drift between them.
create function public.admin_delete_reports(
  requested_token text,
  requested_report_ids uuid[],
  requested_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  session_username text;
  target record;
  deleted_count integer := 0;
  reason_text text;
  snapshots jsonb := '[]'::jsonb;
begin
  select account.username
  into session_username
  from public.admin_sessions as session
  join public.admin_accounts as account on account.id = session.admin_id
  where session.token_hash = encode(extensions.digest(requested_token, 'sha256'), 'hex')
    and session.expires_at > now()
    and account.is_active = true
  limit 1;

  if session_username is null then
    raise exception 'ADMIN_SESSION_REQUIRED' using errcode = '42501';
  end if;

  if requested_report_ids is null or array_length(requested_report_ids, 1) is null then
    raise exception 'REPORT_IDS_REQUIRED' using errcode = '22023';
  end if;

  if array_length(requested_report_ids, 1) > 200 then
    raise exception 'TOO_MANY_REPORT_IDS' using errcode = '22023';
  end if;

  reason_text := nullif(btrim(coalesce(requested_reason, '')), '');

  -- The reason is what the author is shown, so it is not optional. An admin
  -- deleting a report without a reason produces a notice the author cannot act
  -- on, which is the situation this whole migration exists to prevent.
  if reason_text is null or char_length(reason_text) not between 4 and 1000 then
    raise exception 'DELETION_REASON_REQUIRED' using errcode = '22023';
  end if;

  for target in
    select report.id, report.user_id, report.author_username, report.title,
           report.category, report.channel, report.status, report.review_status,
           report.signal_score, report.created_at
    from public.practice_reports as report
    where report.id = any (requested_report_ids)
    for update
  loop
    snapshots := snapshots || jsonb_build_object(
      'report_id', target.id,
      'author_username', target.author_username,
      'title', target.title,
      'category', target.category,
      'channel', target.channel,
      'status', target.status,
      'review_status', target.review_status,
      'signal_score', target.signal_score,
      'created_at', target.created_at
    );
  end loop;

  if jsonb_array_length(snapshots) = 0 then
    -- Reported rather than treated as a no-op. A delete that matched nothing
    -- looks identical to a successful delete from the caller's side, and would
    -- hide a stale id in the admin pane.
    raise exception 'REPORT_NOT_FOUND' using errcode = '22023';
  end if;

  -- Tombstone first. It references profiles, not practice_reports, so it
  -- survives the delete that follows.
  insert into public.report_deletions (
    report_id, owner_id, author_title, reason, deleted_by
  )
  select
  -- jsonb_build_object stringifies the uuid, so ->> yields text and the insert
  -- needs the cast back.
  (snapshot->>'report_id')::uuid,
  report.user_id,
  snapshot->>'title',
  reason_text,
  session_username
  from jsonb_array_elements(snapshots) as snapshot
  join public.practice_reports as report
    on report.id = (snapshot->>'report_id')::uuid
  on conflict (report_id) do nothing;

  delete from public.practice_reports as report
  where report.id in (
    select (snapshot->>'report_id')::uuid
    from jsonb_array_elements(snapshots) as snapshot
  );

  deleted_count := jsonb_array_length(snapshots);

  perform public.write_admin_audit(
    requested_token,
    case
      when deleted_count = 1 then 'report.delete'
      else 'report.bulk_delete'
    end,
    'practice_reports',
    coalesce(snapshots->0->>'report_id', 'none'),
    jsonb_build_object(
      'count', deleted_count,
      'reason', reason_text,
      'reports', snapshots
    )
  );

  return jsonb_build_object(
    'deleted_count', deleted_count,
    'reason', reason_text,
    'reports', snapshots
  );
end;
$$;

revoke all on function public.admin_delete_reports(text, uuid[], text) from public;
grant execute on function public.admin_delete_reports(text, uuid[], text) to anon;

-- ---------------------------------------------------------------------------
-- 5. Feedback reaches the single and bulk review paths
-- ---------------------------------------------------------------------------

-- Both wrappers exist so the admin console has one call per shape, and both
-- delegate to apply_report_review, so the feedback argument has to be threaded
-- through each. Dropped first because create or replace cannot add a parameter,
-- and a stale five-argument overload would keep accepting a rejection with no
-- reason, silently reintroducing the gap this migration closes.
drop function if exists public.admin_update_report(text, uuid, text, text, text);

create function public.admin_update_report(
  requested_token text,
  requested_report_id uuid,
  requested_status text,
  requested_review_status text,
  requested_note text default null,
  requested_feedback text default null
)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  return public.apply_report_review(
    requested_token,
    array[requested_report_id],
    requested_status,
    requested_review_status,
    requested_note,
    requested_feedback
  ) > 0;
end;
$$;

revoke all on function public.admin_update_report(text, uuid, text, text, text, text) from public;
grant execute on function public.admin_update_report(text, uuid, text, text, text, text) to anon;

drop function if exists public.admin_bulk_update_reports(text, uuid[], text, text, text);

create function public.admin_bulk_update_reports(
  requested_token text,
  requested_report_ids uuid[],
  requested_status text,
  requested_review_status text,
  requested_note text default null,
  requested_feedback text default null
)
returns integer
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  return public.apply_report_review(
    requested_token,
    requested_report_ids,
    requested_status,
    requested_review_status,
    requested_note,
    requested_feedback
  );
end;
$$;

revoke all on function public.admin_bulk_update_reports(text, uuid[], text, text, text, text) from public;
grant execute on function public.admin_bulk_update_reports(text, uuid[], text, text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- 6. Reading the current feedback back
-- ---------------------------------------------------------------------------

-- The console needs to show what the author is currently being told, otherwise
-- saving an empty note would silently clear a reason they were given.
--
-- Deliberately not a column on admin_list_reports: create or replace cannot
-- change a returns table, so adding one would mean duplicating that function's
-- whole body into this file. The pane already fetches per report for the
-- history, so this rides along with that call.
create function public.admin_get_report_feedback(
  requested_token text,
  requested_report_id uuid
)
returns text
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  session_username text;
  current_feedback text;
begin
  select account.username
  into session_username
  from public.admin_sessions as session
  join public.admin_accounts as account on account.id = session.admin_id
  where session.token_hash = encode(extensions.digest(requested_token, 'sha256'), 'hex')
    and session.expires_at > now()
    and account.is_active = true
  limit 1;

  if session_username is null then
    raise exception 'ADMIN_SESSION_REQUIRED' using errcode = '42501';
  end if;

  select report.reviewer_feedback
  into current_feedback
  from public.practice_reports as report
  where report.id = requested_report_id;

  return current_feedback;
end;
$$;

revoke all on function public.admin_get_report_feedback(text, uuid) from public;
grant execute on function public.admin_get_report_feedback(text, uuid) to anon;
