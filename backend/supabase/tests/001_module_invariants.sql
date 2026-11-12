-- Trigger and constraint tests.
--
-- Run with: npx supabase test db
--
-- The whole file runs in one transaction that is rolled back, so the fixtures
-- never reach a real database.

begin;

select plan(35);

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------

create temporary table fixture_module as
select module.id, module.position
from public.modules as module
where module.is_active = true
  and module.is_published = true
  and module.content_key is not null
order by module.position
limit 1;

create temporary table fixture_next_module as
select module.id, module.position
from public.modules as module
where module.is_active = true
  and module.is_published = true
  and module.content_key is not null
  and module.position > 1
order by module.position
limit 1;

create temporary table fixture_user as
select gen_random_uuid() as user_id;

insert into auth.users (
  instance_id,
  id,
  aud,
  role,
  email,
  encrypted_password,
  email_confirmed_at,
  created_at,
  updated_at,
  raw_app_meta_data,
  raw_user_meta_data
)
values (
  '00000000-0000-0000-0000-000000000000',
  (select user_id from fixture_user),
  'authenticated',
  'authenticated',
  'trigger-test@example.invalid',
  extensions.crypt('trigger-test-password', extensions.gen_salt('bf', 4)),
  now(),
  now(),
  now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  '{"username":"trigger_test"}'::jsonb
);

-- handle_new_auth_user normally creates this row. The explicit insert keeps the
-- test independent of that trigger's username-derivation rules.
insert into public.profiles (id, username, email)
select user_id, 'trigger_test', 'trigger-test@example.invalid'
from fixture_user
on conflict (id) do nothing;

-- The user-facing RPCs resolve the caller from auth.uid(), so the fixture needs
-- a JWT claim. It is transaction-local and disappears with the rollback.
select set_config(
  'request.jwt.claims',
  json_build_object(
    'sub', (select user_id::text from fixture_user),
    'role', 'authenticated',
    'is_anonymous', false
  )::text,
  true
);

select is(
  (select count(*)::integer from fixture_module),
  1,
  'catalog exposes at least one published module'
);

-- ::integer because modules.position is smallint and pgTAP's is() is
-- polymorphic on a single type. is(smallint, integer, text) has no match, and
-- int4 -> int2 is an assignment cast rather than an implicit one.
select is(
  (select position from fixture_module)::integer,
  1,
  'the first published module sits at position 1'
);

select is(
  (
    select count(*)::integer
    from public.modules
    where position < 1 or position > 999
  ),
  0,
  'every module position is inside 1..999'
);

-- ---------------------------------------------------------------------------
-- Completion is terminal
-- ---------------------------------------------------------------------------

-- The fixture is a pre-existing completion, so seed it through the same
-- transaction-local trust marker used by the completion RPC.
select set_config('alethia.verified_module_completion', 'on', true);

-- updated_at is NOT NULL with no default; the set_updated_at trigger is
-- BEFORE UPDATE only, so an INSERT that omits it fails outright.
insert into public.user_module_progress (
  user_id,
  module_id,
  status,
  progress_percentage,
  started_at,
  completed_at,
  updated_at
)
select user_id, id, 'completed', 100, now(), now(), now()
from fixture_user, fixture_module;

select set_config('alethia.verified_module_completion', 'off', true);

select is(
  (
    select progress.status
    from public.user_module_progress as progress
    join fixture_user as fixture on fixture.user_id = progress.user_id
    where progress.module_id = (select id from fixture_module)
  ),
  'completed',
  'a completed module row is stored'
);

select throws_ok(
  $$
    update public.user_module_progress
    set status = 'in_progress', progress_percentage = 40, completed_at = null
    where user_id = (select user_id from fixture_user)
      and module_id = (select id from fixture_module)
  $$,
  '23514',
  'MODULE_ALREADY_COMPLETED',
  'a completed module cannot be downgraded to in_progress'
);

select throws_ok(
  $$
    update public.user_module_progress
    set status = 'not_started', progress_percentage = 0, started_at = null, completed_at = null
    where user_id = (select user_id from fixture_user)
      and module_id = (select id from fixture_module)
  $$,
  '23514',
  'MODULE_ALREADY_COMPLETED',
  'a completed module cannot be reset to not_started'
);

select throws_ok(
  $$
    update public.user_module_progress
    set completed_at = now() + interval '1 day'
    where user_id = (select user_id from fixture_user)
      and module_id = (select id from fixture_module)
  $$,
  '23514',
  'MODULE_COMPLETION_TIMESTAMP_IMMUTABLE',
  'completed_at cannot be moved once written'
);

-- The guard must not interfere with a module that is still open.
insert into public.user_module_progress (
  user_id,
  module_id,
  status,
  progress_percentage,
  started_at,
  updated_at
)
select fixture_user.user_id, fixture_next_module.id, 'in_progress', 10, now(), now()
from fixture_user, fixture_next_module;

select is(
  (
    select count(*)::integer
    from public.user_module_progress as progress
    join fixture_user as fixture on fixture.user_id = progress.user_id
    where progress.status = 'in_progress'
  ),
  1,
  'a second module can be in progress at the same time'
);

-- One row per (user_id, module_id). A second completion for the same module is
-- a primary key violation, which is the structural half of the guarantee.
-- This is a fixture-only privileged insert; normal clients cannot set the
-- transaction-local server-verification marker.
select set_config('alethia.verified_module_completion', 'on', true);
select throws_ok(
  $$
    insert into public.user_module_progress (
      user_id, module_id, status, progress_percentage, started_at, completed_at, updated_at
    )
    select user_id, id, 'completed', 100, now(), now(), now()
    from fixture_user, fixture_module
  $$,
  '23505',
  null,
  'a user cannot hold two rows for the same module'
);
select set_config('alethia.verified_module_completion', 'off', true);

-- ---------------------------------------------------------------------------
-- Access state
-- ---------------------------------------------------------------------------

-- The position argument is smallint. int4 -> int2 is an assignment cast, not
-- implicit, so a bare integer literal does not resolve the function.
select is(
  public.module_access_state((select user_id from fixture_user), 1::smallint, 'not_started'),
  'available',
  'position 1 is always available'
);

select is(
  public.module_access_state((select user_id from fixture_user), 2::smallint, 'not_started'),
  'locked',
  'an unscored historical completion does not unlock position 2'
);

select is(
  public.module_access_state((select user_id from fixture_user), 1::smallint, 'completed'),
  'available',
  'an unscored historical completion remains available for a verified replay'
);

-- Position 3's immediate predecessor is position 2, which the fixture above
-- left in_progress, so it is the one slot that is still locked.
select is(
  public.module_access_state((select user_id from fixture_user), 3::smallint, 'not_started'),
  'locked',
  'a position whose immediate predecessor is unfinished is locked'
);

select is(
  public.module_access_state(
    (select user_id from fixture_user),
    (select position from fixture_next_module),
    'not_started'
  ),
  'locked',
  'an unscored historical completion keeps the next module locked'
);

-- ---------------------------------------------------------------------------
-- Point ledger idempotency
-- ---------------------------------------------------------------------------

-- The fixture completed a module above, and a module completion is worth points
-- (20260927000000), so compare manual awards against this starting balance.
create temporary table fixture_balance_before as
select profile.points as points
from public.profiles as profile
where profile.id = (select user_id from fixture_user);

create temporary table fixture_ledger_count as
select count(*)::integer as row_count
from public.user_point_ledger as ledger
where ledger.user_id = (select user_id from fixture_user);

select public.award_points(
  (select user_id from fixture_user),
  40, 'achievement_reward', 'module', 'trigger-test-source'
);

select is(
  (
    select profile.points - fixture.points
    from public.profiles as profile, fixture_balance_before as fixture
    where profile.id = (select user_id from fixture_user)
  ),
  40,
  'a first award credits the profile balance'
);

-- The same source a second time. This is the double award the ledger key
-- exists to prevent.
select public.award_points(
  (select user_id from fixture_user),
  40, 'achievement_reward', 'module', 'trigger-test-source'
);

select is(
  (
    select profile.points - fixture.points
    from public.profiles as profile, fixture_balance_before as fixture
    where profile.id = (select user_id from fixture_user)
  ),
  40,
  'replaying the same source does not credit twice'
);

select is(
  (
    select count(*)::integer
    from public.user_point_ledger as ledger
    where ledger.user_id = (select user_id from fixture_user)
  ) - (select row_count from fixture_ledger_count),
  1,
  'the ledger holds exactly one row for that source'
);

-- Same id, different source_type: a genuinely different award.
select public.award_points(
  (select user_id from fixture_user),
  5, 'achievement_reward', 'achievement', 'trigger-test-source'
);

select is(
  (
    select count(*)::integer
    from public.user_point_ledger as ledger
    where ledger.user_id = (select user_id from fixture_user)
  ) - (select row_count from fixture_ledger_count),
  2,
  'the same id under a different source_type is a distinct award'
);

-- The completion trigger stamps notified_at in the same transaction that
-- completes the row, so by the time this runs the module is fully processed.
select is(
  public.is_module_rewardable((select id from fixture_module)),
  false,
  'a completed module whose notification was written is no longer rewardable'
);

-- And it is false for a module that was never completed.
select is(
  public.is_module_rewardable((select id from fixture_next_module)),
  false,
  'a module that is only in progress is not rewardable'
);

-- ---------------------------------------------------------------------------
-- Points and level (20260927000000)
-- ---------------------------------------------------------------------------

select is(
  (
    select count(*)::integer
    from public.user_point_ledger as ledger
    where ledger.user_id = (select user_id from fixture_user)
      and ledger.reason = 'module_completion'
  ),
  1,
  'a first module completion credits exactly one module_completion row'
);

select is(
  (
    select ledger.amount
    from public.user_point_ledger as ledger
    where ledger.user_id = (select user_id from fixture_user)
      and ledger.reason = 'module_completion'
  ),
  public.module_points((select id from fixture_module)),
  'the credited amount is the module own point value'
);

savepoint before_replay;

select throws_ok(
  $$
    update public.user_module_progress
    set completed_at = completed_at + interval '1 second'
    where user_id = (select user_id from fixture_user)
      and module_id = (select id from fixture_module)
  $$,
  '23514',
  'MODULE_COMPLETION_TIMESTAMP_IMMUTABLE',
  'a replayed completion cannot move completed_at'
);

rollback to savepoint before_replay;

select is(
  (
    select count(*)::integer
    from public.user_point_ledger as ledger
    where ledger.user_id = (select user_id from fixture_user)
      and ledger.reason = 'module_completion'
  ),
  1,
  'a replayed completion does not credit a second time'
);

select is(
  (
    select profile.level
    from public.profiles as profile
    where profile.id = (select user_id from fixture_user)
  ),
  public.level_for_points(
    (
      select profile.points
      from public.profiles as profile
      where profile.id = (select user_id from fixture_user)
    )
  ),
  'the stored level always agrees with the point balance'
);

select is(
  (select level_for_points(0) < level_for_points(150) and level_for_points(150) = 3),
  true,
  'the level curve maps a cleared day to level 3'
);

-- ---------------------------------------------------------------------------
-- Notification read model
-- ---------------------------------------------------------------------------

insert into public.notifications (user_id, type, title, body, dedupe_key)
values (
  (select user_id from fixture_user),
  'system',
  'Read model test',
  'Body text long enough to satisfy the length check.',
  'trigger-test-dedupe'
);

select is(
  (
    select read_at is null
    from public.notifications
    where dedupe_key = 'trigger-test-dedupe'
  ),
  true,
  'an unread notification has no read_at'
);

update public.notifications
set is_read = true
where dedupe_key = 'trigger-test-dedupe';

select is(
  (
    select read_at is not null
    from public.notifications
    where dedupe_key = 'trigger-test-dedupe'
  ),
  true,
  'setting is_read derives read_at'
);

-- is_read is authoritative: clearing it clears read_at even when a writer tries
-- to keep the old timestamp.
update public.notifications
set is_read = false, read_at = now()
where dedupe_key = 'trigger-test-dedupe';

select is(
  (
    select read_at is null
    from public.notifications
    where dedupe_key = 'trigger-test-dedupe'
  ),
  true,
  'clearing is_read clears read_at'
);

select throws_ok(
  $$
    insert into public.notifications (user_id, type, title, body, dedupe_key)
    values (
      (select user_id from fixture_user),
      'system', 'Duplicate', 'Duplicate dedupe key body.', 'trigger-test-dedupe'
    )
  $$,
  '23505',
  null,
  'dedupe_key is globally unique'
);

-- ---------------------------------------------------------------------------
-- Registry
-- ---------------------------------------------------------------------------

select is(
  (
    select count(*)::integer
    from public.daily_quests as quest
    where quest.quest_type not in (
      select registry.quest_type from public.quest_event_registry as registry
    )
  ),
  0,
  'every quest points at a registered quest_type'
);

select throws_ok(
  $$
    insert into public.quest_event_registry (quest_type, event_key, label, description)
    values ('daily_login', 'duplicate', 'Duplicate', 'Duplicate registry entry body.')
  $$,
  '23505',
  null,
  'a quest_type cannot be registered twice'
);

-- ---------------------------------------------------------------------------
-- Streak split
-- ---------------------------------------------------------------------------

-- Completing a module writes the practice streak. It must not write the daily
-- streak, which belongs to record_daily_activity.
select is(
  (
    select count(*)::integer
    from public.user_streaks as streak
    where streak.user_id = (select user_id from fixture_user)
  ),
  1,
  'completing a module creates a practice streak row'
);

select is(
  (
    select count(*)::integer
    from public.user_daily_streaks as streak
    where streak.user_id = (select user_id from fixture_user)
  ),
  0,
  'completing a module does not create a daily streak row'
);

select is(
  (
    select streak.current_streak
    from public.user_streaks as streak
    where streak.user_id = (select user_id from fixture_user)
  ),
  1,
  'the practice streak starts at 1 on a first completion'
);

select * from finish();
rollback;
