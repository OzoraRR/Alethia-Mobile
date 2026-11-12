update public.modules
set
  title_id = 'Social Engineering',
  title_en = 'Social Engineering'
where id = 'social-engineering'
  and (
    title_id is distinct from 'Social Engineering'
    or title_en is distinct from 'Social Engineering'
  );
