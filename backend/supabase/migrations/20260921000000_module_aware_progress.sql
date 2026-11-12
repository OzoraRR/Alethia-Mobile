-- Discover generated check-constraint names at migration time rather than guessing them.
do $$
declare
  module_constraint record;
begin
  for module_constraint in
    select conrelid::regclass as relation_name, conname
    from pg_constraint
    where contype = 'c'
      and conrelid in ('public.practice_attempts'::regclass, 'public.user_module_progress'::regclass)
      and pg_get_constraintdef(oid) like '%module_id%'
  loop
    execute format('alter table %s drop constraint %I', module_constraint.relation_name, module_constraint.conname);
  end loop;
end $$;

alter table public.practice_attempts
  add constraint practice_attempts_module_id_check
  check (module_id in ('courier-sms', 'social-engineering'));

alter table public.user_module_progress
  add constraint user_module_progress_module_id_check
  check (module_id in ('courier-sms', 'social-engineering'));
