-- Allow a report owner to edit user-authored content or delete their report.
-- Server-managed identity, moderation, and signal fields remain immutable.

alter table public.practice_reports enable row level security;

drop policy if exists practice_reports_update_own on public.practice_reports;
create policy practice_reports_update_own
  on public.practice_reports
  for update
  to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()));

drop policy if exists practice_reports_delete_own on public.practice_reports;
create policy practice_reports_delete_own
  on public.practice_reports
  for delete
  to authenticated
  using (user_id = (select auth.uid()));

create or replace function public.protect_practice_report_system_fields()
returns trigger
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
begin
  if new.id is distinct from old.id
     or new.user_id is distinct from old.user_id
     or new.author_username is distinct from old.author_username
     or new.source is distinct from old.source
     or new.signal_score is distinct from old.signal_score
     or new.review_status is distinct from old.review_status
     or new.status is distinct from old.status
     or new.reviewed_by is distinct from old.reviewed_by
     or new.reviewed_at is distinct from old.reviewed_at
     or new.created_at is distinct from old.created_at then
    raise exception 'PRACTICE_REPORT_SYSTEM_FIELDS_IMMUTABLE' using errcode = '42501';
  end if;

  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists practice_reports_protect_system_fields on public.practice_reports;
create trigger practice_reports_protect_system_fields
  before update on public.practice_reports
  for each row execute function public.protect_practice_report_system_fields();

revoke all on function public.protect_practice_report_system_fields() from public;

grant update, delete on table public.practice_reports to authenticated;

comment on policy practice_reports_update_own on public.practice_reports is
  'Owners may update report content; a trigger protects identity, moderation, and signal fields.';
comment on policy practice_reports_delete_own on public.practice_reports is
  'Owners may delete their report; related signals and notes cascade.';
