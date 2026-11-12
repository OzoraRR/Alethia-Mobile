-- Realtime publication for the notification bell and the daily quest panel.
--
-- A table is only delivered over Supabase Realtime once it is a member of the
-- supabase_realtime publication. Without this the browser subscription connects
-- successfully and then silently receives nothing, which is indistinguishable
-- from a broken poll.
--
-- ---------------------------------------------------------------------------
-- READ THIS BEFORE ASSUMING IT WORKED
-- ---------------------------------------------------------------------------
-- On a hosted Supabase project this statement does NOT usually succeed. The
-- supabase_realtime publication is owned by the supabase_admin role, and
-- migrations run as postgres, which is neither the owner nor a member of it, so
-- ALTER PUBLICATION raises 42501 "must be owner of publication". The handler
-- below catches that and prints a NOTICE, which `supabase db push` does not
-- display. The migration is then recorded as applied with none of its work done.
--
-- Run this once, in the Supabase SQL editor or the CLI, as an owner of the
-- publication:
--
--   alter publication supabase_realtime add table public.notifications;
--   alter publication supabase_realtime add table public.user_daily_quests;
--
-- Verify it took effect:
--
--   select tablename from pg_publication_tables
--    where pubname = 'supabase_realtime' and schemaname = 'public';
--
-- Both tables are safe to publish because RLS still applies to the realtime
-- server: a subscriber only receives rows its own policy would let it select.
-- Both have a user_id = auth.uid() select policy, so a channel carries one
-- account's data only.
--
-- Realtime is an optimisation, never the source of truth. Polling on focus and
-- on visibility remains the fallback, and assignment and streak maintenance
-- happen in record_daily_activity rather than in the browser, so a tab that was
-- closed still records correctly on its next load.

do $$
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    raise notice
      'supabase_realtime is absent. Run the ALTER PUBLICATION statements from the header manually.';
    return;
  end if;

  execute $pub$
    alter publication supabase_realtime add table public.notifications
  $pub$;

  execute $pub$
    alter publication supabase_realtime add table public.user_daily_quests
  $pub$;

  raise notice 'supabase_realtime now carries notifications and user_daily_quests.';
exception
  when others then
    -- Expected on hosted Supabase. Say so loudly in the log rather than
    -- silently reporting success.
    raise warning
      'Could not alter supabase_realtime (%). Realtime is optional: run the two ALTER PUBLICATION statements from the header of 20260926080000 as the publication owner. The app still works without it.',
      sqlerrm;
end;
$$;
