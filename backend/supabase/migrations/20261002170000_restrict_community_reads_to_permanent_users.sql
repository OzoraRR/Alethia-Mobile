-- Supabase anonymous Auth users use the `authenticated` database role too.
-- These reports and investigation records are only for permanent accounts.
-- Restrictive policies compose with permissive policies using AND, so another
-- permissive SELECT policy cannot accidentally reopen anonymous access.

drop policy if exists practice_reports_require_permanent_reader
  on public.practice_reports;
create policy practice_reports_require_permanent_reader
  on public.practice_reports
  as restrictive
  for select
  to authenticated
  using ((select (auth.jwt() ->> 'is_anonymous')::boolean) is false);

drop policy if exists report_signals_require_permanent_reader
  on public.report_signals;
create policy report_signals_require_permanent_reader
  on public.report_signals
  as restrictive
  for select
  to authenticated
  using ((select (auth.jwt() ->> 'is_anonymous')::boolean) is false);

drop policy if exists report_investigation_notes_require_permanent_reader
  on public.report_investigation_notes;
create policy report_investigation_notes_require_permanent_reader
  on public.report_investigation_notes
  as restrictive
  for select
  to authenticated
  using ((select (auth.jwt() ->> 'is_anonymous')::boolean) is false);

drop policy if exists report_verdicts_require_permanent_reader
  on public.report_verdicts;
create policy report_verdicts_require_permanent_reader
  on public.report_verdicts
  as restrictive
  for select
  to authenticated
  using ((select (auth.jwt() ->> 'is_anonymous')::boolean) is false);
