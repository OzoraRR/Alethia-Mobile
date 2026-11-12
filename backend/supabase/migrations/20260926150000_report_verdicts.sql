-- Investigator verdicts on community reports.
--
-- Investigators (two finished modules) can mark a report valid or invalid.
-- The verdict is display-only: it never hides, locks, or deletes the report.
-- An invalid report stays public with its badge, exactly like a valid one.
-- Moderation (queued/approved/rejected) stays a separate developer concern.

alter table public.practice_reports
  add column if not exists investigator_verdict text
    check (investigator_verdict is null or investigator_verdict in ('valid', 'invalid')),
  add column if not exists verdict_by uuid references public.profiles (id) on delete set null,
  add column if not exists verdict_at timestamptz;

create or replace function public.set_report_verdict(
  requested_report_id uuid,
  requested_verdict text
)
returns boolean
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  current_user_id uuid := (select auth.uid());
  completed_count integer;
begin
  if current_user_id is null then
    raise exception 'AUTHENTICATION_REQUIRED' using errcode = '42501';
  end if;
  if requested_verdict is null
    or (requested_verdict <> 'valid' and requested_verdict <> 'invalid')
  then
    raise exception 'INVALID_VERDICT' using errcode = '22023';
  end if;
  -- The investigator bar lives here, not only in the client: two finished
  -- modules, read from the maintained aggregate so a forged request gains
  -- nothing.
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

  update public.practice_reports
  set investigator_verdict = requested_verdict,
    verdict_by = current_user_id,
    verdict_at = now(),
    updated_at = now()
  where practice_reports.id = requested_report_id;
  return true;
end;
$$;

revoke all on function public.set_report_verdict(uuid, text) from public;
grant execute on function public.set_report_verdict(uuid, text) to authenticated;
