-- `profiles.level` is a projection of points, not a client-editable fact.
-- The original trigger only fired when points changed, so an owner could write
-- `level = 5` directly and publish an inconsistent profile projection.
-- Widen the trigger event list without changing the points-award path.
drop trigger if exists profiles_sync_level on public.profiles;
create trigger profiles_sync_level
  before insert or update of points, level on public.profiles
  for each row execute function public.sync_profile_level();

comment on trigger profiles_sync_level on public.profiles is
  'Keeps level derived from points, including when a client attempts to update level directly.';
