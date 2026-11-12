-- Privilege hygiene: three functions from 20260924000000 were never revoked.
--
-- handle_new_auth_user, handle_auth_user_update and protect_profile_identity all
-- RETURN trigger, so a direct call raises "trigger functions can only be called
-- as triggers" and none of them is exploitable today. The first two are
-- SECURITY DEFINER, though, and a SECURITY DEFINER function left executable by
-- PUBLIC is the wrong default: if either is ever converted to a plain function,
-- or a trigger is dropped, the privilege is already there waiting.
--
-- Every other function introduced since then is revoked. These three were simply
-- missed, because the revokes in the later migrations only cover the objects
-- those migrations create.

revoke all on function public.handle_new_auth_user() from public;
revoke all on function public.handle_auth_user_update() from public;
revoke all on function public.protect_profile_identity() from public;

comment on function public.handle_new_auth_user() is
  'Creates a public profile for each new Supabase auth user. Trigger-only; not callable directly.';
comment on function public.handle_auth_user_update() is
  'Mirrors auth.users email changes into the profile projection. Trigger-only; not callable directly.';
comment on function public.protect_profile_identity() is
  'Blocks browser writes to profile identity fields. Trigger-only; not callable directly.';
