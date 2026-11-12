begin;
select plan(5);

select ok(
  not has_function_privilege('authenticated', 'public.set_report_verdict(uuid, text)', 'EXECUTE'),
  'authenticated clients cannot call the legacy verdict-cache RPC'
);
select ok(
  not has_function_privilege('anon', 'public.set_report_verdict(uuid, text)', 'EXECUTE'),
  'anonymous clients cannot call the legacy verdict-cache RPC'
);
select ok(
  has_function_privilege('authenticated', 'public.cast_report_verdict(uuid, text, text)', 'EXECUTE'),
  'authenticated investigators retain the reason-bearing vote RPC'
);
select ok(
  not has_function_privilege('anon', 'public.cast_report_verdict(uuid, text, text)', 'EXECUTE'),
  'anonymous clients cannot call the reason-bearing vote RPC'
);
select ok(
  not has_function_privilege('service_role', 'public.cast_report_verdict(uuid, text, text)', 'EXECUTE'),
  'service-role clients cannot cast user-attributed report votes'
);

select * from finish();
rollback;
