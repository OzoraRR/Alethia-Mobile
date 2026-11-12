begin;
select plan(14);

-- Exercise the owner-only password path with an ephemeral value that is never
-- stored in the repository or sent to a hosted project.
create temporary table admin_password_test as
select encode(extensions.gen_random_bytes(24), 'hex') as chosen_password;
create temporary table admin_hash_before as
select id, password_hash
from public.admin_accounts
where lower(username) = 'alethia';

select ok(
  (select count(*) = 1 and bool_and(is_active) from public.admin_accounts where lower(username) = 'alethia'),
  'the Alethia admin account exists and is active'
);
select ok(
  (select password_hash like '$2%' from public.admin_accounts where lower(username) = 'alethia'),
  'the stored admin credential is a bcrypt hash'
);

insert into public.admin_sessions (admin_id, token_hash, expires_at)
select account.id, encode(extensions.digest('admin-password-test-token', 'sha256'), 'hex'), now() + interval '1 hour'
from public.admin_accounts as account
where lower(account.username) = 'alethia';

select is(
  (select count(*)::integer from public.admin_sessions session join public.admin_accounts account on account.id = session.admin_id where lower(account.username) = 'alethia'),
  1,
  'a session exists before changing the password'
);
select is(
  public.admin_set_password((select chosen_password from admin_password_test)),
  'ok',
  'the owner-only password function accepts an operator-chosen value'
);
select ok(
  (select account.password_hash = extensions.crypt(test.chosen_password, account.password_hash)
   from public.admin_accounts account cross join admin_password_test test where lower(account.username) = 'alethia'),
  'the chosen value authenticates against the stored hash'
);
select ok(
  (select account.password_hash is distinct from prior.password_hash
   from public.admin_accounts account join admin_hash_before prior on prior.id = account.id),
  'changing the credential replaces the prior hash'
);
select is(
  (select count(*)::integer from public.admin_sessions session join public.admin_accounts account on account.id = session.admin_id where lower(account.username) = 'alethia'),
  0,
  'changing the password revokes existing sessions'
);
select throws_ok(
  $$select public.admin_set_password('ab')$$,
  '22023',
  'ADMIN_PASSWORD_TOO_SHORT',
  'the manual password function rejects a short value'
);
savepoint admin_password_missing_account;
update public.admin_accounts
set username = 'alethia_test'
where lower(username) = 'alethia';
select throws_ok(
  $$select public.admin_set_password('temporary-test-value')$$,
  'P0002',
  'ADMIN_ACCOUNT_NOT_FOUND',
  'the manual password function reports a missing Alethia admin account'
);
rollback to savepoint admin_password_missing_account;
select is(has_function_privilege('anon', 'public.admin_set_password(text)', 'execute'), false,
  'anonymous clients cannot change the admin password');
select is(has_function_privilege('authenticated', 'public.admin_set_password(text)', 'execute'), false,
  'authenticated clients cannot change the admin password');
select is(has_function_privilege('service_role', 'public.admin_set_password(text)', 'execute'), false,
  'the service role cannot change the admin password');
select is(has_function_privilege('postgres', 'public.admin_set_password(text)', 'execute'), true,
  'the database owner can change the admin password manually');
select is(
  (select count(*)::integer from pg_proc proc join pg_namespace ns on ns.oid = proc.pronamespace
   cross join (values ('anon'), ('authenticated'), ('service_role')) roles(rolname)
   where ns.nspname = 'public' and proc.proname in ('admin_set_password', 'admin_bootstrap_password')
     and has_function_privilege(roles.rolname, proc.oid, 'execute')),
  0,
  'manual password functions remain unreachable to browser roles'
);

select * from finish();
rollback;
