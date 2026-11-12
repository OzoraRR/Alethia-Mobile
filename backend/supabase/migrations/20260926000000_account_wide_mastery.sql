-- Mastery is account-wide, but the write path only ever stored it on the
-- courier-sms row, so a learner who finished social-engineering or the document
-- module first stayed on `not_started` in the database as well as in the UI.
--
-- This migration:
--   1. ranks the mastery values so the furthest level wins,
--   2. rewrites every completed module row for accounts that finished anything,
--   3. refreshes the profiles projection from the repaired rows,
--   4. keeps the habit flags consistent across module rows.

with ranked as (
  select
    progress.user_id,
    progress.mastery_level,
    row_number() over (
      partition by progress.user_id
      order by case progress.mastery_level
        when 'skilled' then 1
        when 'needs_practice' then 2
        when 'familiar' then 3
        else 4
      end
    ) as mastery_rank
  from public.user_module_progress as progress
  where progress.status = 'completed'
    and progress.mastery_level <> 'not_started'
)
update public.user_module_progress as progress
set mastery_level = ranked.mastery_level
from ranked
where progress.user_id = ranked.user_id
  and progress.status = 'completed'
  and ranked.mastery_rank = 1
  and progress.mastery_level is distinct from ranked.mastery_level;

-- Habits were also read from courier-sms only; a habit practised in any module
-- applies to the whole account.
with habit_totals as (
  select
    user_id,
    bool_or(inspect_practised) as inspect_practised,
    bool_or(verify_practised) as verify_practised,
    bool_or(report_practised) as report_practised
  from public.user_module_progress
  group by user_id
)
update public.user_module_progress as progress
set inspect_practised = habits.inspect_practised,
    verify_practised = habits.verify_practised,
    report_practised = habits.report_practised
from habit_totals as habits
where progress.user_id = habits.user_id
  and (
    progress.inspect_practised is distinct from habits.inspect_practised
    or progress.verify_practised is distinct from habits.verify_practised
    or progress.report_practised is distinct from habits.report_practised
  );

update public.profiles as profile
set mastery = coalesce(
      (
        select progress.mastery_level
        from public.user_module_progress as progress
        where progress.user_id = profile.id
          and progress.status = 'completed'
        order by case progress.mastery_level
          when 'skilled' then 1
          when 'needs_practice' then 2
          when 'familiar' then 3
          else 4
        end
        limit 1
      ),
      profile.mastery
    ),
    modules_completed = greatest(
      profile.modules_completed,
      (
        select count(*)::integer
        from public.user_module_progress as progress
        where progress.user_id = profile.id
          and progress.status = 'completed'
      )
    );
