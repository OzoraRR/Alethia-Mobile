begin;
select plan(9);

select ok(
  not has_function_privilege('anon', 'public.consume_username_login_rate_limit(text)', 'execute'),
  'anonymous callers cannot consume or inspect login rate limits'
);
select ok(
  not has_function_privilege('authenticated', 'public.consume_username_login_rate_limit(text)', 'execute'),
  'authenticated callers cannot consume or inspect login rate limits'
);
select ok(
  has_function_privilege('service_role', 'public.consume_username_login_rate_limit(text)', 'execute'),
  'the backend service role can consume login rate limits'
);
select ok(
  not has_table_privilege('anon', 'public.username_login_rate_limits', 'select'),
  'anonymous callers cannot read rate-limit identities'
);
select ok(
  not has_table_privilege('service_role', 'public.username_login_rate_limits', 'select'),
  'the backend service role cannot bypass the rate-limit RPC to read identities'
);

create temporary table username_login_rate_limit_fixture (
  identity_hash text primary key
) on commit drop;
insert into username_login_rate_limit_fixture
  values (encode(extensions.digest(gen_random_uuid()::text, 'sha256'), 'hex'));

do $$
declare
  fixture_hash text;
  attempt_allowed boolean;
  attempt_index integer;
begin
  select fixture.identity_hash into fixture_hash
    from pg_temp.username_login_rate_limit_fixture as fixture;
  for attempt_index in 1..30 loop
    select result.allowed into attempt_allowed
      from public.consume_username_login_rate_limit(fixture_hash) as result;
    if not attempt_allowed then
      raise exception 'USERNAME_LOGIN_RATE_LIMIT_BLOCKED_EARLY';
    end if;
  end loop;
end;
$$;

select is(
  (select attempt_count::integer from public.username_login_rate_limits
   where identity_hash=(select identity_hash from username_login_rate_limit_fixture)),
  30,
  'the first 30 requests in a window are allowed and counted'
);

select is(
  (select allowed from public.consume_username_login_rate_limit(
    (select identity_hash from username_login_rate_limit_fixture)
  )),
  false,
  'the next request is blocked'
);

select ok(
  (select retry_after_seconds between 1 and 900
   from public.consume_username_login_rate_limit(
     (select identity_hash from username_login_rate_limit_fixture)
   )),
  'blocked requests receive a bounded Retry-After value'
);

select throws_ok(
  $$select * from public.consume_username_login_rate_limit('not-a-hmac')$$,
  '22023',
  'INVALID_USERNAME_LOGIN_RATE_LIMIT_IDENTITY',
  'the RPC rejects malformed identifiers'
);

select * from finish();
rollback;
