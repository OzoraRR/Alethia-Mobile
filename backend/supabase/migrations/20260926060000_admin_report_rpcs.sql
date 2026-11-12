-- Report moderation: paged reads, bulk transitions, and a real history.
--
-- admin_list_reports previously returned the entire practice_reports table,
-- unbounded and unfiltered, on every dashboard render. It also could not show
-- a screenshot, because screenshots were stored as data URLs up to 700 KB and
-- were therefore left out of the projection entirely.
--
--   * screenshot_path replaces the data URL in the admin projection. The data
--     URL column stays for the owner-facing client and is no longer read by any
--     list RPC.
--   * admin_list_reports is paged and filterable, which is what the list pane
--     and its infinite scroll need.
--   * admin_bulk_update_reports applies one transition to many ids and writes
--     the same review history a single update writes.
--   * Every transition records who did it, what changed, and the note.

-- ---------------------------------------------------------------------------
-- 1. screenshot_path
-- ---------------------------------------------------------------------------

alter table public.practice_reports
  add column if not exists screenshot_path text;

alter table public.practice_reports
  drop constraint if exists practice_reports_screenshot_path_check;

-- A Storage object key, so the pattern allows uppercase (bucket prefixes like
-- "Screenshots/" are legitimate) and rejects only what could not be a key:
-- a leading slash, a traversal segment, and control characters.
alter table public.practice_reports
  add constraint practice_reports_screenshot_path_check
  check (
    screenshot_path is null
    or (
      char_length(screenshot_path) between 1 and 512
      and screenshot_path !~ '(^|/)\.\.(/|$)'
      and screenshot_path ~ '^[A-Za-z0-9][A-Za-z0-9._/-]*$'
    )
  );

comment on column public.practice_reports.screenshot_path is
  'Private Storage object key for the report screenshot. Preferred over screenshot_data_url, which is capped at 700 KB and never returned by an admin list RPC. Not moderation-protected, so an owner may repoint their own attachment; Storage RLS bounds what that key can reach.';

-- ---------------------------------------------------------------------------
-- 2. admin_list_reports, paged and filterable
-- ---------------------------------------------------------------------------

-- The previous admin_list_reports took a single argument and returned a fixed
-- 13-column projection with no filters and no paging. CREATE OR REPLACE cannot
-- change either, so it is dropped rather than replaced.
-- Arity must match the create below. `drop function if exists` never errors, so
-- a wrong arity is a silent no-op today and a silent destroy the day a matching
-- signature appears.
drop function if exists public.admin_list_reports(
  text, text, text, date, date, text, integer, integer
);

create function public.admin_list_reports(
  requested_token text,
  requested_review_status text default null,
  requested_sort text default null,
  requested_created_from date default null,
  requested_created_to date default null,
  requested_search text default null,
  requested_limit integer default 50,
  requested_offset integer default 0
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
  clamped_offset integer := greatest(0, coalesce(requested_offset, 0));
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

  -- The same three orders the user-facing report hub offers, so an admin looking
  -- at a report sees it in the order a user would. Unknown values fall back to
  -- newest rather than erroring: this is a display preference, not an input the
  -- caller can get wrong in a way that matters.
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
  -- Ordering is one ORDER BY with mutually exclusive keys rather than three
  -- separate queries, because paging has to happen after ordering. For a given
  -- sort_key exactly one branch is active and the rest evaluate to NULL for
  -- every row, so they are all equal to one another and cannot reorder
  -- anything. That is why the per-direction NULL defaults (ASC is NULLS LAST,
  -- DESC is NULLS FIRST) do not matter.
  order by
    case when sort_key = 'oldest' then report.created_at end asc,
    case when sort_key = 'oldest' then report.id end asc,
    case when sort_key = 'newest' then report.created_at end desc,
    case when sort_key = 'newest' then report.id end desc,
    case when sort_key = 'top' then report.signal_score end desc,
    case when sort_key = 'top' then report.created_at end desc
  limit clamped_limit
  offset clamped_offset;
end;
$$;

revoke all on function public.admin_list_reports(
  text, text, text, date, date, text, integer, integer
) from public;
grant execute on function public.admin_list_reports(
  text, text, text, date, date, text, integer, integer
) to anon;

-- Count companion so the list pane can tell "end of results" from "page empty".
-- Its filters must mirror admin_list_reports exactly, minus ordering and paging.
create or replace function public.admin_count_reports(
  requested_token text,
  requested_review_status text default null,
  requested_created_from date default null,
  requested_created_to date default null,
  requested_search text default null
)
returns integer
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  search_term text := nullif(btrim(coalesce(requested_search, '')), '');
  total_count integer;
begin
  -- An invalid token must not read as "no reports", which the UI cannot
  -- distinguish from an empty result set.
  if not exists (select 1 from public.admin_session_info(requested_token)) then
    raise exception 'ADMIN_SESSION_REQUIRED' using errcode = '42501';
  end if;

  select count(*)::integer
  into total_count
  from public.practice_reports as report
  where (requested_review_status is null or report.review_status = requested_review_status)
    and (requested_created_from is null or report.created_at >= requested_created_from::timestamptz)
    and (requested_created_to is null or report.created_at < (requested_created_to::date + 1)::timestamptz)
    and (
      search_term is null
      or report.title ilike '%' || search_term || '%'
      or report.author_username ilike '%' || search_term || '%'
      or report.evidence ilike '%' || search_term || '%'
    );

  return total_count;
end;
$$;

revoke all on function public.admin_count_reports(text, text, date, date, text) from public;
grant execute on function public.admin_count_reports(text, text, date, date, text) to anon;

-- ---------------------------------------------------------------------------
-- 3. Shared transition writer
-- ---------------------------------------------------------------------------

-- One implementation for single and bulk updates, so the history, the audit
-- entry and the reviewed_by attribution cannot diverge between the two paths.
create or replace function public.apply_report_review(
  requested_token text,
  requested_report_ids uuid[],
  requested_status text,
  requested_review_status text,
  requested_note text default null
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
        -- practice_reports.reviewed_by is a uuid FK to public.profiles, NOT to
        -- admin_accounts. The two id spaces are independent gen_random_uuid()
        -- values and an operator has no profiles row, so writing
        -- admin_accounts.id raises a foreign key violation and aborts the whole
        -- moderation path. It stays NULL.
        --
        -- Attribution comes from report_review_events.actor_username, written
        -- above in the same call, which records the real reviewer as a username
        -- and is the field the admin UI reads. Clearing it on re-queue is also
        -- what practice_reports_review_check requires: a queued report must have
        -- reviewed_by and reviewed_at both null.
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
        'status', requested_status,
        'review_status', requested_review_status,
        'has_note', nullif(btrim(coalesce(requested_note, '')), '') is not null
      )
    );
  end if;

  return change_count;
end;
$$;

revoke all on function public.apply_report_review(text, uuid[], text, text, text) from public;
grant execute on function public.apply_report_review(text, uuid[], text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- 4. admin_update_report and admin_bulk_update_reports
-- ---------------------------------------------------------------------------

-- requested_note is new, so the four-argument object is dropped first. Arity
-- matches the create below; a mismatch here is a silent no-op, not an error.
drop function if exists public.admin_update_report(text, uuid, text, text);

create function public.admin_update_report(
  requested_token text,
  requested_report_id uuid,
  requested_status text,
  requested_review_status text,
  requested_note text default null
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
    requested_note
  ) > 0;
end;
$$;

revoke all on function public.admin_update_report(text, uuid, text, text, text) from public;
grant execute on function public.admin_update_report(text, uuid, text, text, text) to anon;

create or replace function public.admin_bulk_update_reports(
  requested_token text,
  requested_report_ids uuid[],
  requested_status text,
  requested_review_status text,
  requested_note text default null
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
    requested_note
  );
end;
$$;

revoke all on function public.admin_bulk_update_reports(text, uuid[], text, text, text) from public;
grant execute on function public.admin_bulk_update_reports(text, uuid[], text, text, text) to anon;

-- ---------------------------------------------------------------------------
-- 5. Review history read
-- ---------------------------------------------------------------------------

create or replace function public.admin_report_review_history(
  requested_token text,
  requested_report_id uuid
)
returns table (
  id uuid,
  actor_username text,
  previous_status text,
  previous_review_status text,
  next_status text,
  next_review_status text,
  note text,
  created_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
begin
  if not exists (select 1 from public.admin_session_info(requested_token)) then
    raise exception 'ADMIN_SESSION_REQUIRED' using errcode = '42501';
  end if;

  return query
  select
    event.id,
    event.actor_username,
    event.previous_status,
    event.previous_review_status,
    event.next_status,
    event.next_review_status,
    event.note,
    event.created_at
  from public.report_review_events as event
  where event.report_id = requested_report_id
  order by event.created_at desc, event.id desc;
end;
$$;

revoke all on function public.admin_report_review_history(text, uuid) from public;
grant execute on function public.admin_report_review_history(text, uuid) to anon;
