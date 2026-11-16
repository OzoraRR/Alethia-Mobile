-- UI recovery data is not score/progress authority. Existing verified RPCs remain responsible for rewards.
create table public.learning_sessions (
  user_id uuid not null references public.profiles(id) on delete cascade,
  module_id text not null references public.modules(id),
  attempt_id uuid not null references public.practice_attempts(id) on delete cascade,
  revision bigint not null default 0,
  state jsonb not null default '{}'::jsonb check (jsonb_typeof(state) = 'object' and octet_length(state::text) <= 24576),
  updated_at timestamptz not null default now(),
  primary key(user_id, module_id)
);
alter table public.learning_sessions enable row level security;
revoke all on public.learning_sessions from anon, authenticated;

create function public.get_learning_sessions() returns jsonb
language plpgsql stable security definer set search_path = pg_catalog as $$
begin
  perform public.require_permanent_account();
  return coalesce((select jsonb_agg(to_jsonb(s) - 'user_id') from public.learning_sessions s where s.user_id=auth.uid()), '[]'::jsonb);
end;
$$;

create function public.open_learning_session(requested_module_id text, requested_restart boolean default false) returns jsonb
language plpgsql security definer set search_path = pg_catalog as $$
declare draft public.learning_sessions; attempt uuid;
begin
  perform public.require_permanent_account();
  perform pg_advisory_xact_lock(hashtextextended(auth.uid()::text || ':' || requested_module_id, 0));
  if not public.is_module_unlocked(requested_module_id) then raise exception 'MODULE_LOCKED' using errcode='42501'; end if;
  select * into draft from public.learning_sessions where user_id=auth.uid() and module_id=requested_module_id for update;
  if found and not requested_restart then return to_jsonb(draft) - 'user_id'; end if;
  attempt := public.begin_verified_practice_attempt(requested_module_id);
  insert into public.learning_sessions(user_id,module_id,attempt_id,revision,state)
    values(auth.uid(),requested_module_id,attempt,0,'{}')
    on conflict(user_id,module_id) do update set attempt_id=excluded.attempt_id, revision=0,state='{}',updated_at=now()
    returning * into draft;
  return to_jsonb(draft) - 'user_id';
end;
$$;

create function public.save_learning_session(requested_attempt_id uuid, requested_revision bigint, requested_state jsonb) returns jsonb
language plpgsql security definer set search_path = pg_catalog as $$
declare draft public.learning_sessions;
begin
  perform public.require_permanent_account();
  if requested_state is null or jsonb_typeof(requested_state) <> 'object' or octet_length(requested_state::text) > 24576 then
    raise exception 'INVALID_LEARNING_STATE' using errcode='22023';
  end if;
  select * into draft from public.learning_sessions where user_id=auth.uid() and attempt_id=requested_attempt_id for update;
  if not found then raise exception 'SESSION_NOT_FOUND' using errcode='42501'; end if;
  -- An identical retry after a lost response returns the existing revision.
  if draft.state = requested_state then return to_jsonb(draft) - 'user_id'; end if;
  if draft.revision <> requested_revision then raise exception 'SESSION_REVISION_CONFLICT' using errcode='40001'; end if;
  update public.learning_sessions set state=requested_state, revision=revision+1,updated_at=now()
    where user_id=auth.uid() and attempt_id=requested_attempt_id returning * into draft;
  return to_jsonb(draft) - 'user_id';
end;
$$;
revoke all on function public.get_learning_sessions() from public, anon;
revoke all on function public.open_learning_session(text,boolean) from public, anon;
revoke all on function public.save_learning_session(uuid,bigint,jsonb) from public, anon;
grant execute on function public.get_learning_sessions(), public.open_learning_session(text,boolean), public.save_learning_session(uuid,bigint,jsonb) to authenticated;
comment on table public.learning_sessions is 'Account-scoped UI recovery snapshots. Never used to authorize completion, points or module unlocks.';
