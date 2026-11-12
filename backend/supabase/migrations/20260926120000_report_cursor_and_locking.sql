-- Keyset pagination and optimistic locking for report moderation.
--
-- Two defects, both of which lose data rather than erroring.
--
-- Offset pagination. admin_list_reports used limit/offset. A moderation queue
-- grows while it is being read, so a row inserted between two page requests
-- shifts every later row forward by one and the operator sees a report twice,
-- or not at all. The fix is a cursor: the last row's sort key, compared with a
-- row-value comparison so the existing indexes still apply.
--
-- Optimistic locking. Two moderators open the same report. Both type a note.
-- The second write wins and the first note is gone, with no record that it ever
-- existed. review_version makes that visible: a single-report review states the
-- version it read, and a mismatch is refused rather than silently overwriting.
--
-- Bulk review deliberately does not check versions. An operator who selected
-- forty reports and chose "approve" means it, and refusing because a row moved
-- underneath them would be worse than the problem being solved. Bulk still
-- increments the version, so a later single edit on any of those rows detects
-- that someone else has touched it since.
--
-- This is a new file rather than an edit to 20260926060000. Editing a migration
-- that has already been applied changes nothing on the remote database; the
-- alter simply never runs there.

-- ---------------------------------------------------------------------------
-- 1. Version column
-- ---------------------------------------------------------------------------

alter table public.practice_reports
  add column if not exists review_version integer not null default 0;

comment on column public.practice_reports.review_version is
  'Incremented on every moderation write. A single-report review passes the version it read so a concurrent edit is refused instead of overwritten.';

-- The guard trigger blocks clients from writing moderation fields. The version is
-- one of them, or a client could bump it to invalidate every operator's open
-- editor.
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
       or new.review_version is distinct from old.review_version
       or new.created_at is distinct from old.created_at
     ) then
    raise exception 'PRACTICE_REPORT_SYSTEM_FIELDS_IMMUTABLE' using errcode = '42501';
  end if;

  new.updated_at := now();
  return new;
end;
$$;

-- The top sort's cursor is (signal_score, created_at, id). Without the id in the
-- index, a tie on the first two columns forces a sort of everything after the
-- cursor, which is the case keyset pagination is supposed to avoid.
create index if not exists practice_reports_signal_cursor_idx
  on public.practice_reports (signal_score desc, created_at desc, id desc);

-- ---------------------------------------------------------------------------
-- 2. Single-report state for the detail pane
-- ---------------------------------------------------------------------------

-- Replaces admin_get_report_feedback from 20260926110000, which returned one
-- column. The detail pane needs the version and the feedback together, and it
-- needs them read at the moment of action rather than carried from the list: a
-- version fetched when the list rendered may already be stale, which would make
-- the check refuse valid edits.
create or replace function public.admin_get_report_state(
  requested_token text,
  requested_report_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  session_username text;
  current_state jsonb;
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

  select jsonb_build_object(
    'reviewer_feedback', report.reviewer_feedback,
    'review_version', report.review_version,
    'review_status', report.review_status,
    'status', report.status
  )
  into current_state
  from public.practice_reports as report
  where report.id = requested_report_id;

  if current_state is null then
    raise exception 'REPORT_NOT_FOUND' using errcode = '22023';
  end if;

  return current_state;
end;
$$;

revoke all on function public.admin_get_report_state(text, uuid) from public;
grant execute on function public.admin_get_report_state(text, uuid) to anon;

-- Superseded rather than kept, so there is one function answering this and a
-- caller cannot pick the one that omits the version.
drop function if exists public.admin_get_report_feedback(text, uuid);

-- ---------------------------------------------------------------------------
-- 3. Review writer takes an expected version
-- ---------------------------------------------------------------------------

drop function if exists public.apply_report_review(text, uuid[], text, text, text, text);

create function public.apply_report_review(
  requested_token text,
  requested_report_ids uuid[],
  requested_status text,
  requested_review_status text,
  requested_note text default null,
  requested_feedback text default null,
  requested_expected_version integer default null
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
  stale_ids uuid[] := '{}'::uuid[];
  change_count integer;
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
    raise exception 'REVIEW_FEEDBACK_REQUIRED' using errcode = '22023';
  end if;

  if feedback_value is not null
     and char_length(feedback_value) not between 4 and 2000 then
    raise exception 'REVIEW_FEEDBACK_TOO_LONG' using errcode = '22023';
  end if;

  for target in
    select report.id, report.status, report.review_status, report.review_version
    from public.practice_reports as report
    where report.id = any (requested_report_ids)
    for update
  loop
    if requested_expected_version is not null
       and target.review_version <> requested_expected_version then
      stale_ids := stale_ids || target.id;
      continue;
    end if;

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

  -- Refused before anything is written, so a stale single-report edit cannot
  -- half-apply. The ids are named so the pane can say which report moved.
  if array_length(stale_ids, 1) is not null then
    raise exception 'REPORT_VERSION_CONFLICT: %', array_to_string(stale_ids, ',')
      using errcode = '40001', detail = stale_ids::text;
  end if;

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
        review_version = report.review_version + 1,
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
        'reviewer_feedback', to_jsonb(feedback_value),
        'expected_version', to_jsonb(requested_expected_version)
      )
    );
  end if;

  return change_count;
end;
$$;

revoke all on function public.apply_report_review(text, uuid[], text, text, text, text, integer) from public;
grant execute on function public.apply_report_review(text, uuid[], text, text, text, text, integer) to anon;

drop function if exists public.admin_update_report(text, uuid, text, text, text, text);

create function public.admin_update_report(
  requested_token text,
  requested_report_id uuid,
  requested_status text,
  requested_review_status text,
  requested_note text default null,
  requested_feedback text default null,
  requested_expected_version integer default null
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
    requested_feedback,
    requested_expected_version
  ) > 0;
end;
$$;

revoke all on function public.admin_update_report(text, uuid, text, text, text, text, integer) from public;
grant execute on function public.admin_update_report(text, uuid, text, text, text, text, integer) to anon;

drop function if exists public.admin_bulk_update_reports(text, uuid[], text, text, text, text);

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
  -- No expected version: a bulk action is an explicit decision about a set, and
  -- refusing it because a row moved would defeat the point of selecting many.
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
-- 4. Cursor-paged list
-- ---------------------------------------------------------------------------
--
-- The cursor is the sort key of the last row of the previous page. Each sort has
-- a different key, so the three cursor parameters are per-sort and the caller
-- sends the ones matching the sort it asked for.
--
--   newest  (created_at desc, id desc)              cursor_created_at
--   oldest  (created_at asc,  id asc)               cursor_created_at
--   top     (signal_score desc, created_at desc)    cursor_signal_score
--
-- The function returns one row more than asked for. The caller uses it like
-- this:
--
--   rows.length <= limit     -> no more results
--   rows.length == limit + 1 -> display rows[0 .. limit-1]
--                              next cursor is the key of rows[limit-1]
--
-- The cursor is the last row DISPLAYED, not the extra row. Taking it from the
-- extra row skips exactly one report per page: it becomes the cursor, so the
-- next page starts strictly after it and it is never shown to anyone. The extra
-- row exists only to prove that more results exist, which is otherwise
-- indistinguishable from a final page that happens to be full.
--
-- An earlier version returned explicit next_cursor_* columns computed with
-- row_number() and lag() over a sentinel row, and took the cursor from the wrong
-- side of that boundary. Returning limit + 1 rows and letting the caller take
-- the key it already has removes the window functions and the duplicated sort
-- keys from the return type entirely.
--
-- Why the return type keeps review_event_count but no version: the detail pane
-- reads the version through admin_get_report_state at the moment of action, not
-- from a list that may be several minutes stale.

create or replace function public.admin_list_reports_cursor(
  requested_token text,
  requested_review_status text default null,
  requested_sort text default null,
  requested_created_from date default null,
  requested_created_to date default null,
  requested_search text default null,
  requested_limit integer default 50,
  requested_after_created_at timestamptz default null,
  requested_after_id uuid default null,
  requested_after_signal_score integer default null
)
returns table (
  id uuid,
  title text,
  author_username text,
  category text,
  channel text,
  pattern text,
  evidence text,
  why_risky text,
  defanged_url text,
  status text,
  review_status text,
  admin_note text,
  screenshot_path text,
  has_screenshot boolean,
  signal_score integer,
  created_at timestamptz,
  reviewed_at timestamptz,
  review_event_count integer
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  clamped_limit integer := greatest(1, least(coalesce(requested_limit, 50), 200));
  search_term text := nullif(btrim(coalesce(requested_search, '')), '');
  sort_key text := coalesce(nullif(btrim(coalesce(requested_sort, '')), ''), 'newest');
begin
  if not exists (select 1 from public.admin_session_info(requested_token)) then
    raise exception 'ADMIN_SESSION_REQUIRED' using errcode = '42501';
  end if;

  if requested_review_status is not null
     and requested_review_status not in ('queued', 'approved', 'rejected') then
    raise exception 'INVALID_REPORT_STATUS' using errcode = '22023';
  end if;

  if sort_key not in ('newest', 'oldest', 'top') then
    sort_key := 'newest';
  end if;

  return query
  select
    report.id,
    report.title,
    report.author_username,
    report.category,
    report.channel,
    report.pattern,
    report.evidence,
    report.why_risky,
    report.defanged_url,
    report.status,
    report.review_status,
    report.admin_note,
    report.screenshot_path,
    (report.screenshot_path is not null or report.screenshot_data_url is not null),
    report.signal_score,
    report.created_at,
    report.reviewed_at,
    (
      select count(*)::integer
      from public.report_review_events as event
      where event.report_id = report.id
    )
  from public.practice_reports as report
  where (requested_review_status is null or report.review_status = requested_review_status)
    and (requested_created_from is null or report.created_at >= requested_created_from::timestamptz)
    and (requested_created_to is null or report.created_at < (requested_created_to::date + 1)::timestamptz)
    and (
      search_term is null
      or report.title ilike '%' || search_term || '%'
      or report.author_username ilike '%' || search_term || '%'
      or report.evidence ilike '%' || search_term || '%'
    )
    -- Cursor predicates. Row-value comparison, so each is a single index range
    -- scan rather than a disjunction for the planner to combine.
    and (
      sort_key <> 'newest'
      or requested_after_created_at is null
      or (report.created_at, report.id) < (requested_after_created_at, requested_after_id)
    )
    and (
      sort_key <> 'oldest'
      or requested_after_created_at is null
      or (report.created_at, report.id) > (requested_after_created_at, requested_after_id)
    )
    and (
      sort_key <> 'top'
      or requested_after_signal_score is null
      or (report.signal_score, report.created_at, report.id)
           < (requested_after_signal_score, requested_after_created_at, requested_after_id)
    )
  order by
    -- Mutually exclusive keys: exactly one branch is active for a given
    -- sort_key and the rest are NULL for every row, so they are all equal to one
    -- another and cannot reorder anything.
    case when sort_key = 'oldest' then report.created_at end asc,
    case when sort_key = 'oldest' then report.id end asc,
    case when sort_key = 'newest' then report.created_at end desc,
    case when sort_key = 'newest' then report.id end desc,
    case when sort_key = 'top' then report.signal_score end desc,
    case when sort_key = 'top' then report.created_at end desc,
    case when sort_key = 'top' then report.id end desc
  -- One extra row, which the caller treats as the cursor rather than as content.
  limit clamped_limit + 1;
end;
$$;

revoke all on function public.admin_list_reports_cursor(text, text, text, date, date, text, integer, timestamptz, uuid, integer) from public;
grant execute on function public.admin_list_reports_cursor(text, text, text, date, date, text, integer, timestamptz, uuid, integer) to anon;

comment on function public.admin_list_reports_cursor(text, text, text, date, date, text, integer, timestamptz, uuid, integer) is
  'Cursor-paged replacement for admin_list_reports. Returns one row more than requested_limit: the caller displays the first requested_limit rows and uses the extra row''s sort key as the next cursor. Fewer rows than requested_limit means the results are exhausted.';
