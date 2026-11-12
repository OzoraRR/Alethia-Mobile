-- Realtime publication guard.
--
-- supabase_realtime is owned by supabase_admin. Migrations run as postgres, so
-- 20260926080000 cannot add the tables itself and the step is done by hand in
-- the Supabase SQL Editor. That is the whole problem: a manual step that fails
-- leaves no trace. Realtime simply stops delivering rows, notifications stop
-- arriving, and nothing in the application reports an error.
--
-- So this file is a tripwire, not a local test. On the throwaway cluster the
-- local verify script builds there is no supabase_realtime publication, so every
-- assertion skips and the file contributes nothing. Run it against a real
-- project and it either passes or names exactly which table is missing:
--
--     psql "$DATABASE_URL" -f supabase/tests/007_realtime_publication.sql
--
-- To fix a failure:
--     alter publication supabase_realtime add table public.notifications;
--     alter publication supabase_realtime add table public.user_daily_quests;

begin;

select plan(3);

-- has_table, not hasnt_table. An earlier version of this file asserted the
-- tables were absent, which is the exact opposite of what is wanted, and it
-- failed for a reason that looked like a pgTAP overload problem rather than an
-- inverted assertion.
select has_table('public'::name, 'notifications'::name, 'notifications table exists');

select has_table('public'::name, 'user_daily_quests'::name, 'user_daily_quests table exists');

-- Detected up front, because skipping has to be decided before the assertion
-- runs. A `skip` placed after a failing `ok` does not skip anything: the
-- assertion has already failed by then.
create temporary table realtime_env as
select exists (select 1 from pg_publication where pubname = 'supabase_realtime') as has_publication;

-- One test either way, so the plan stays at three. skip(why text, how_many
-- integer) is cast explicitly because pgTAP also has skip(text) and
-- skip(integer), and an uncast pair of literals is ambiguous.
select case
  when (select has_publication from realtime_env) then
    ok(
      (
        select count(*) = 2
        from pg_publication_tables
        where pubname = 'supabase_realtime'
          and schemaname = 'public'
          and tablename in ('notifications', 'user_daily_quests')
      ),
      'both realtime tables are members of supabase_realtime'
    )
  else
    skip(
      'supabase_realtime is absent on this cluster, so this says nothing about a real project. Run this file against one to check it.'
      ::text,
      1
    )
end;

select * from finish();
rollback;
