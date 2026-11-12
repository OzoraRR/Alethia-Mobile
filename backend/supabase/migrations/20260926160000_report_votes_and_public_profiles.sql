-- Report interaction round two: named comments, verdict votes with reasons.
--
-- 1. Investigation notes gain the author's username. Notes already carry
--    user_id, but profiles are owner-readable only, so no client can resolve
--    another author's name. The username is denormalised at write time (like
--    practice_reports.author_username) and backfilled for existing rows.
-- 2. Verdicts become votes. One row per investigator per report with a
--    mandatory reason, so the page can show HOW MANY said valid vs invalid
--    and WHY. practice_reports.investigator_verdict stays as the latest-vote
--    cache for list badges.

-- ---------------------------------------------------------------------------
-- 1. Note authors
-- ---------------------------------------------------------------------------

alter table public.report_investigation_notes
  add column if not exists author_username text;

create or replace function public.set_note_author()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  select profile.username
  into new.author_username
  from public.profiles as profile
  where profile.id = new.user_id;
  return new;
end;
$$;

drop trigger if exists report_investigation_notes_set_author on public.report_investigation_notes;
create trigger report_investigation_notes_set_author
  before insert on public.report_investigation_notes
  for each row execute function public.set_note_author();

-- Backfill through the same join the trigger uses. Runs as owner, so the
-- profiles RLS that hides other users from clients does not apply here.
update public.report_investigation_notes as note
set author_username = profile.username
from public.profiles as profile
where profile.id = note.user_id
  and note.author_username is null;

revoke all on function public.set_note_author() from public;

comment on column public.report_investigation_notes.author_username is
  'Denormalised author name so any signed-in user can see who investigated. Written by trigger, never by clients.';

-- ---------------------------------------------------------------------------
-- 2. Verdict votes
-- ---------------------------------------------------------------------------

create table public.report_verdicts (
  report_id uuid not null references public.practice_reports (id) on delete cascade,
  user_id uuid not null references public.profiles (id) on delete cascade,
  author_username text,
  verdict text not null check (verdict in ('valid', 'invalid')),
  reason text not null check (char_length(btrim(reason)) between 4 and 2000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (report_id, user_id)
);

comment on table public.report_verdicts is
  'One vote per investigator per report, each with a mandatory reason. practice_reports.investigator_verdict caches the latest vote for list badges.';

comment on column public.report_verdicts.author_username is
  'Denormalised voter name so any signed-in user can see who voted. Written by cast_report_verdict, never by clients.';
create index report_verdicts_report_idx
  on public.report_verdicts (report_id, created_at desc);

alter table public.report_verdicts enable row level security;

drop policy if exists report_verdicts_select_authenticated on public.report_verdicts;
create policy report_verdicts_select_authenticated
  on public.report_verdicts
  for select
  to authenticated
  using (true);

-- No insert policy on purpose: writes go through cast_report_verdict, which
-- enforces the investigator bar. An open insert would let any account vote.

revoke all on table public.report_verdicts from anon;
grant select on table public.report_verdicts to authenticated;

create or replace function public.cast_report_verdict(
  requested_report_id uuid,
  requested_verdict text,
  requested_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  current_user_id uuid := (select auth.uid());
  completed_count integer;
  clean_reason text := nullif(btrim(coalesce(requested_reason, '')), '');
  valid_count integer;
  invalid_count integer;
begin
  if current_user_id is null then
    raise exception 'AUTHENTICATION_REQUIRED' using errcode = '42501';
  end if;
  if requested_verdict is null
    or (requested_verdict <> 'valid' and requested_verdict <> 'invalid')
  then
    raise exception 'INVALID_VERDICT' using errcode = '22023';
  end if;
  if clean_reason is null or char_length(clean_reason) not between 4 and 2000 then
    raise exception 'VERDICT_REASON_REQUIRED' using errcode = '22023';
  end if;
  select coalesce(profiles.modules_completed, 0) into completed_count
  from public.profiles
  where profiles.id = current_user_id;
  if completed_count is null or completed_count < 2 then
    raise exception 'INVESTIGATOR_REQUIRED' using errcode = '42501';
  end if;
  if not exists (
    select 1 from public.practice_reports
    where practice_reports.id = requested_report_id
  ) then
    raise exception 'REPORT_NOT_FOUND' using errcode = '22023';
  end if;

  insert into public.report_verdicts as vote (report_id, user_id, verdict, reason, updated_at)
  values (requested_report_id, current_user_id, requested_verdict, clean_reason, now())
  on conflict (report_id, user_id) do update
  set verdict = excluded.verdict,
      reason = excluded.reason,
      updated_at = now();

  -- The voter name is denormalised like note authors: profiles are
  -- owner-readable only, so no client can resolve another voter's name.
  update public.report_verdicts as vote
  set author_username = profile.username
  from public.profiles as profile
  where vote.report_id = requested_report_id
    and vote.user_id = current_user_id
    and profile.id = current_user_id;

  -- Latest vote wins the public badge. Counting a majority instead would let
  -- an old consensus hide a fresh correction; the full vote list below it
  -- shows every position anyway.
  update public.practice_reports as report
  set investigator_verdict = requested_verdict,
      verdict_by = current_user_id,
      verdict_at = now(),
      updated_at = now()
  where report.id = requested_report_id;

  select
    count(*) filter (where vote.verdict = 'valid'),
    count(*) filter (where vote.verdict = 'invalid')
  into valid_count, invalid_count
  from public.report_verdicts as vote
  where vote.report_id = requested_report_id;

  return jsonb_build_object('valid', valid_count, 'invalid', invalid_count);
end;
$$;

revoke all on function public.cast_report_verdict(uuid, text, text) from public;
grant execute on function public.cast_report_verdict(uuid, text, text) to authenticated;

comment on function public.cast_report_verdict(uuid, text, text) is
  'Records one investigator vote with a mandatory reason and refreshes the public verdict cache to the latest vote.';

-- ---------------------------------------------------------------------------
-- 3. Public profiles
-- ---------------------------------------------------------------------------

-- Just enough for a public dossier: identity, level inputs, and counts. No
-- email, no points, no streaks, no locale. Resolved from auth.uid() nowhere,
-- so any signed-in user can read any dossier by username.
create or replace function public.get_public_profile(requested_username text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare
  target_id uuid;
  result jsonb;
begin
  select profile.id
  into target_id
  from public.profiles as profile
  where profile.username is not null
    and lower(profile.username) = lower(btrim(coalesce(requested_username, '')));

  if target_id is null then
    raise exception 'PROFILE_NOT_FOUND' using errcode = '22023';
  end if;

  select jsonb_build_object(
    'username', profile.username,
    'modules_completed', profile.modules_completed,
    'mastery', profile.mastery,
    'badges', coalesce((
      select jsonb_agg(badge.badge_code order by badge.badge_code)
      from public.user_profile_badges as badge
      where badge.user_id = target_id
        and badge.selected = true
    ), '[]'::jsonb),
    'report_count', (
      select count(*) from public.practice_reports as report
      where report.user_id = target_id
    ),
    'reports', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id', report.id,
          'title', report.title,
          'created_at', report.created_at,
          'signal_score', report.signal_score,
          'review_status', report.review_status,
          'investigator_verdict', report.investigator_verdict
        )
        order by report.created_at desc
      )
      from public.practice_reports as report
      where report.user_id = target_id
    ), '[]'::jsonb),
    'investigations', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'report_id', note.report_id,
          'report_title', report.title,
          'created_at', note.created_at
        )
        order by note.created_at desc
      )
      from public.report_investigation_notes as note
      left join public.practice_reports as report on report.id = note.report_id
      where note.user_id = target_id
    ), '[]'::jsonb)
  )
  into result
  from public.profiles as profile
  where profile.id = target_id;

  return result;
end;
$$;

revoke all on function public.get_public_profile(text) from public;
grant execute on function public.get_public_profile(text) to authenticated;

comment on function public.get_public_profile(text) is
  'Public dossier by username: identity, level inputs, their reports and their investigations. No email, points, streaks or locale.';
