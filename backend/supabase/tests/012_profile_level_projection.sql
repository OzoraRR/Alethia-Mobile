begin;
select plan(2);

create temporary table fixture_user as select gen_random_uuid() as user_id;
insert into auth.users (
  instance_id,id,aud,role,email,encrypted_password,email_confirmed_at,created_at,updated_at,
  raw_app_meta_data,raw_user_meta_data
)
select
  '00000000-0000-0000-0000-000000000000',user_id,'authenticated','authenticated',
  'level-projection-test@example.invalid',extensions.crypt('test',extensions.gen_salt('bf',4)),now(),now(),now(),
  '{"provider":"email","providers":["email"]}'::jsonb,'{"username":"level_projection_test"}'::jsonb
from fixture_user;

select set_config(
  'request.jwt.claims',
  json_build_object('sub',(select user_id::text from fixture_user),'role','authenticated','is_anonymous',false)::text,
  true
);

update public.profiles set level = 5 where id = (select user_id from fixture_user);

select is(
  (
    select profile.level
    from public.profiles as profile
    where profile.id = (select user_id from fixture_user)
  ),
  public.level_for_points(
    (
      select profile.points
      from public.profiles as profile
      where profile.id = (select user_id from fixture_user)
    )
  ),
  'a direct level update is rewritten from the point balance'
);

select is(
  (
    select level = public.level_for_points(points)
    from public.profiles
    where id = (select user_id from fixture_user)
  ),
  true,
  'every stored profile level remains a projection of points'
);

select * from finish();
rollback;
