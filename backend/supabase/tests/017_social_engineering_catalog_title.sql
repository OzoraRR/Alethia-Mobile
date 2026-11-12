begin;
select plan(2);

select is(
  (select title_id from public.modules where id = 'social-engineering'),
  'Social Engineering'::text,
  'the Indonesian catalog title is the module name, not its marketplace scenario'
);
select is(
  (select title_en from public.modules where id = 'social-engineering'),
  'Social Engineering'::text,
  'the English catalog title is the module name, not its marketplace scenario'
);

select * from finish();
rollback;
