-- Fast authenticated bootstrap and bounded, keyset-paginated feeds.
begin;
create or replace function public.unichat_bootstrap() returns jsonb language plpgsql security definer set search_path='' as $$
declare p public.unichat_profiles;access jsonb;preferences jsonb:='{}';personal jsonb:='{}';follows jsonb:='[]';begin
 if auth.uid() is null or not exists(select 1 from auth.users where id=auth.uid()) then raise exception 'Sign in to continue';end if;
 select * into p from public.unichat_profiles where id=auth.uid();access:=public.unichat_access_state();
 if p.status='suspended' and not public.unichat_is_owner() then raise exception 'Your account is suspended. Contact support.';end if;
 if p.id is not null and p.status='active' and public.unichat_site_open() then
  preferences:=public.unichat_my_settings();
  select coalesce(data,'{}') into personal from public.unichat_content where id='state:'||auth.uid()::text and owner=auth.uid() and kind='state';
  select coalesce(jsonb_agg(f.following),'[]') into follows from(select following from public.unichat_follows where follower=auth.uid() limit 10000) f;
 end if;
 return jsonb_build_object('profile',case when p.id is null then null else p.data end,'status',coalesce(p.status,'new'),'settings',(select data from public.unichat_settings where id='published'),'state',coalesce(personal,'{}'),'preferences',preferences,'following',follows,'access',access,
 'own_counts',case when p.id is not null then jsonb_build_object('posts',(select count(*) from public.unichat_content where kind='post' and owner=auth.uid()),'communities',(select count(*) from public.unichat_memberships where user_id=auth.uid())) else '{}'::jsonb end);
end$$;
create or replace function public.unichat_feed_page(feed_mode text default 'all',author_id uuid default null,before_time timestamptz default null,before_id text default null) returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare rows jsonb;mine jsonb;ids text[];counts jsonb;begin
 if not public.unichat_active() then raise exception 'An active account is required';end if;
 if feed_mode not in ('all','campus','following','author','saved') then raise exception 'Unknown feed';end if;
 if feed_mode='author' and (author_id is null or not public.unichat_profile_visible(author_id)) then raise exception 'Profile unavailable';end if;
 select coalesce(data,'{}') into mine from public.unichat_content where id='state:'||auth.uid()::text and owner=auth.uid() and kind='state';
 select coalesce(jsonb_agg(to_jsonb(c) order by c.created_at desc,c.id desc),'[]') into rows from(
  select c.id,c.owner,c.data,c.created_at from public.unichat_content c where c.kind='post' and
  (before_time is null or (c.created_at,c.id)<(before_time,coalesce(before_id,''))) and
  (feed_mode='all' or (feed_mode='campus' and c.data->>'school'=(select data->>'school' from public.unichat_profiles where id=auth.uid())) or
   (feed_mode='following' and (c.owner=auth.uid() or exists(select 1 from public.unichat_follows where follower=auth.uid() and following=c.owner))) or
   (feed_mode='author' and c.owner=author_id) or (feed_mode='saved' and coalesce(mine->'saved','[]'::jsonb)?c.id))
  order by c.created_at desc,c.id desc limit 16
 )c;
 select array_agg(r->>'id') into ids from jsonb_array_elements(rows)r;
 counts:=public.unichat_post_counts(coalesce(ids,'{}'));
 return jsonb_build_object('rows',rows,'counts',counts,'authors',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'username',p.username,'data',jsonb_build_object('name',p.data->>'name','school',p.data->>'school','department',p.data->>'department','level',p.data->>'level','avatar_path',p.data->>'avatar_path'))) from public.unichat_profiles p where p.id in(select (r->>'owner')::uuid from jsonb_array_elements(rows)r)),'[]'),'liked',coalesce((select jsonb_agg(data->>'postId') from public.unichat_content where kind='like' and owner=auth.uid() and data->>'postId'=any(ids)),'[]'));
end$$;
create index if not exists uc_posts_owner_date on public.unichat_content(owner,created_at desc,id desc) where kind='post';
create index if not exists uc_posts_school_date on public.unichat_content((data->>'school'),created_at desc,id desc) where kind='post';
create index if not exists uc_posts_feed_date on public.unichat_content(created_at desc,id desc) where kind='post';
revoke all on function public.unichat_bootstrap(),public.unichat_feed_page(text,uuid,timestamptz,text) from public,anon;
grant execute on function public.unichat_bootstrap(),public.unichat_feed_page(text,uuid,timestamptz,text) to authenticated;
commit;
