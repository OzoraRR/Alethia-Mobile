-- Extend only the named module ID checks created by the earlier migrations.
-- Leave all other constraints and policies unchanged.
alter table public.practice_attempts
  drop constraint practice_attempts_module_id_check;

alter table public.user_module_progress
  drop constraint user_module_progress_module_id_check;

alter table public.practice_attempts
  add constraint practice_attempts_module_id_check
  check (module_id in ('courier-sms', 'social-engineering', 'executable-file'));

alter table public.user_module_progress
  add constraint user_module_progress_module_id_check
  check (module_id in ('courier-sms', 'social-engineering', 'executable-file'));
