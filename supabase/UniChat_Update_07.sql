-- Searchable follower/following lists with viewer-specific visibility and pagination.
begin;
create index if not exists uc_follows_incoming on public.unichat_follows(following,follower);
create or replace function public.unichat_social_visible(student_id uuid) returns boolean language sql stable security definer set search_path='' as $$
 select public.unichat_active() and exists(select 1 from public.unichat_profiles p where p.id=student_id and p.status='active')
 and not exists(select 1 from public.unichat_blocks b where (b.blocker=auth.uid() and b.blocked=student_id) or (b.blocked=auth.uid() and b.blocker=student_id))
$$;
create or replace function public.unichat_follow_counts(student_id uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$begin
 if not public.unichat_social_visible(student_id) then raise exception 'This profile is unavailable';end if;
 return jsonb_build_object(
  'followers',(select count(*) from public.unichat_follows f where f.following=student_id and public.unichat_social_visible(f.follower)),
  'following',(select count(*) from public.unichat_follows f where f.follower=student_id and public.unichat_social_visible(f.following)),
  'viewer_following',exists(select 1 from public.unichat_follows f where f.follower=auth.uid() and f.following=student_id)
 );
end$$;
create or replace function public.unichat_follow_list(student_id uuid,list_kind text,page_offset integer default 0,search_text text default '')
returns table(id uuid,username text,data jsonb,is_following boolean,follows_you boolean)
language plpgsql stable security definer set search_path='' as $$begin
 if not public.unichat_social_visible(student_id) then raise exception 'This profile is unavailable';end if;
 if list_kind is null or list_kind not in ('followers','following') then raise exception 'Choose Followers or Following';end if;
 return query select p.id,p.username,p.data,
  exists(select 1 from public.unichat_follows own where own.follower=auth.uid() and own.following=p.id),
  exists(select 1 from public.unichat_follows own where own.following=auth.uid() and own.follower=p.id)
 from public.unichat_follows f join public.unichat_profiles p
 on p.id=case when list_kind='followers' then f.follower else f.following end
 where case when list_kind='followers' then f.following=student_id else f.follower=student_id end
 and public.unichat_social_visible(p.id)
 and (coalesce(trim(search_text),'')='' or position(lower(left(trim(search_text),100)) in lower(concat_ws(' ',p.username,p.data->>'name',p.data->>'school',p.data->>'department')))>0)
 order by lower(p.data->>'name'),p.id limit 26 offset greatest(0,least(coalesce(page_offset,0),1000000));
end$$;
revoke all on function public.unichat_social_visible(uuid),public.unichat_follow_counts(uuid),public.unichat_follow_list(uuid,text,integer,text) from public,anon;
grant execute on function public.unichat_social_visible(uuid),public.unichat_follow_counts(uuid),public.unichat_follow_list(uuid,text,integer,text) to authenticated;
commit;
