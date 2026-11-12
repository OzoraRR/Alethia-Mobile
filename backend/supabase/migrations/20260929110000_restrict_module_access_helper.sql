-- module_access_state accepts a caller-supplied user id and runs as a definer.
-- It is an internal helper for the verified access RPCs, not a public API.
revoke all on function public.module_access_state(uuid, smallint, text) from public;
