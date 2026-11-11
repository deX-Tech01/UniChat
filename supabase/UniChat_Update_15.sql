-- Update 15: listing/group photos, safe sharing, tagging, and navigable notifications.
begin;
alter table public.unichat_communities add column if not exists photo_path text;
alter table public.unichat_hubs add column if not exists photo_path text;
alter table public.unichat_notifications add column if not exists context jsonb not null default '{}';
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values('unichat-space-photos','unichat-space-photos',false,5242880,array['image/jpeg']) on conflict(id) do nothing;
create or replace function public.unichat_space_photo_upload_allowed(object_name text) returns boolean language plpgsql stable security definer set search_path='' as $$
declare p text[];target uuid;manager uuid;capability text;begin
 if not public.unichat_active() or not public.unichat_feature('uploads') then return false;end if;
 p:=string_to_array(object_name,'/');if cardinality(p)<>4 or p[1]<>auth.uid()::text or p[2] not in ('listing','community','hub') or p[3]!~'^[0-9a-f-]{36}$' or p[4]!~'^[0-9a-f-]{36}\.jpg$' then return false;end if;
 target:=p[3]::uuid;
 if p[2]='listing' then select author,case when kind='marketplace' then 'marketplace' else 'opportunities' end into manager,capability from public.unichat_listings where id=target;capability:=coalesce(capability,'marketplace');
 elsif p[2]='community' then select creator into manager from public.unichat_communities where id=target;capability:='communities';
 else select creator into manager from public.unichat_hubs where id=target;capability:='hubs';end if;
 return public.unichat_feature(capability) and (manager is null or manager=auth.uid() or public.unichat_is_owner());
 exception when invalid_text_representation then return false;
end$$;
create or replace function public.unichat_space_photo_linked(object_name text) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.unichat_listings where photo_path=object_name) or exists(select 1 from public.unichat_communities where photo_path=object_name) or exists(select 1 from public.unichat_hubs where photo_path=object_name)
$$;
create or replace function public.unichat_space_photo_guard() returns trigger language plpgsql security definer set search_path='' as $$
declare category text;meta jsonb;ceiling bigint;begin
 if tg_op='UPDATE' then if new.photo_path is not distinct from old.photo_path then return new;end if;end if;
 if new.photo_path is null then return new;end if;
 category:=case tg_table_name when 'unichat_listings' then 'listing' when 'unichat_hubs' then 'hub' else 'community' end;
 if not public.unichat_space_photo_upload_allowed(new.photo_path) or new.photo_path !~ ('^'||auth.uid()::text||'/'||category||'/'||new.id::text||'/[0-9a-f-]{36}\.jpg$') then raise exception 'Photo does not belong to this item';end if;
 select metadata into meta from storage.objects where bucket_id='unichat-space-photos' and name=new.photo_path;
 if not found then raise exception 'Upload the picture before saving';end if;
 select file_size_limit into ceiling from storage.buckets where id='unichat-space-photos';
 if meta->>'mimetype' is distinct from 'image/jpeg' or coalesce((meta->>'size')::bigint,0) not between 1 and ceiling then raise exception 'Picture type or size is invalid';end if;
 return new;
end$$;
do $$declare t text;begin foreach t in array array['unichat_listings','unichat_hubs','unichat_communities'] loop
 execute format('drop trigger if exists uc_space_photo_guard on public.%I',t);
 execute format('create trigger uc_space_photo_guard before insert or update on public.%I for each row execute function public.unichat_space_photo_guard()',t);
end loop;end$$;
-- SELECT remains subject to the linked item's RLS. Draft images are readable only by their uploader.
drop policy if exists uc_space_photo_read on storage.objects;
create policy uc_space_photo_read on storage.objects for select to authenticated using(bucket_id='unichat-space-photos' and public.unichat_active() and (
 ((storage.foldername(name))[1]=auth.uid()::text and not public.unichat_space_photo_linked(name)) or
 exists(select 1 from public.unichat_listings l where l.photo_path=name and public.unichat_feature(case when l.kind='marketplace' then 'marketplace' else 'opportunities' end)) or
 exists(select 1 from public.unichat_communities c where c.photo_path=name and public.unichat_feature('communities')) or
 exists(select 1 from public.unichat_hubs h where h.photo_path=name and public.unichat_feature('hubs'))));
drop policy if exists uc_space_photo_upload on storage.objects;
create policy uc_space_photo_upload on storage.objects for insert to authenticated with check(bucket_id='unichat-space-photos' and public.unichat_space_photo_upload_allowed(name));
drop policy if exists uc_space_photo_remove on storage.objects;
create policy uc_space_photo_remove on storage.objects for delete to authenticated using(bucket_id='unichat-space-photos' and public.unichat_active() and (storage.foldername(name))[1]=auth.uid()::text and not public.unichat_space_photo_linked(name));
grant delete on public.unichat_listings to authenticated;
drop policy if exists uc_listings_delete on public.unichat_listings;
create policy uc_listings_delete on public.unichat_listings for delete to authenticated using(public.unichat_active() and (author=auth.uid() or public.unichat_is_owner()));

-- Check an audience for a specific student without changing the request identity.
create or replace function public.unichat_post_visible_to(post_id text,student_id uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.unichat_content c join public.unichat_profiles a on a.id=c.owner join public.unichat_profiles s on s.id=student_id where c.id=post_id and c.kind='post' and a.status='active' and s.status='active' and
 (c.owner=student_id or (not exists(select 1 from public.unichat_blocks b where (b.blocker=student_id and b.blocked=c.owner) or (b.blocker=c.owner and b.blocked=student_id)) and
 (coalesce((select profile_visibility from public.unichat_user_settings where user_id=c.owner),'students')='students' or (coalesce((select profile_visibility from public.unichat_user_settings where user_id=c.owner),'students')='followers' and exists(select 1 from public.unichat_follows where follower=student_id and following=c.owner))) and
 (coalesce(c.data->>'audience','students')='students' or (c.data->>'audience'='followers' and exists(select 1 from public.unichat_follows where follower=student_id and following=c.owner))))))
$$;
create or replace function public.unichat_share_guard() returns trigger language plpgsql security definer set search_path='' as $$begin
 if new.kind='message' and new.data->>'shared_post' is not null then
 if not public.unichat_post_visible_to(new.data->>'shared_post',auth.uid()) or not public.unichat_post_visible_to(new.data->>'shared_post',(new.data->>'recipient')::uuid) then raise exception 'This post is not available to both students';end if;
 end if;return new;
end$$;
drop trigger if exists uc_share_guard on public.unichat_content;
create trigger uc_share_guard before insert on public.unichat_content for each row execute function public.unichat_share_guard();

create table if not exists public.unichat_tag_events(actor uuid not null references public.unichat_profiles(id),recipient uuid not null references public.unichat_profiles(id),source_kind text not null,source_id text not null,post_id text not null,primary key(actor,recipient,source_kind,source_id));
alter table public.unichat_tag_events enable row level security;
revoke all on public.unichat_tag_events from public,anon,authenticated;
create or replace function public.unichat_emit_tags(body text,post_id text,source_kind text,source_id text) returns void language plpgsql security definer set search_path='' as $$
declare r record;inserted integer;begin
 for r in select p.id from public.unichat_profiles p where p.username in (
 select distinct lower(m[2]) from regexp_matches(coalesce(body,''),'(^|[^A-Za-z0-9_@])@([A-Za-z0-9_]{3,30})(?![A-Za-z0-9_])','g') m limit 20)
 and p.status='active' and p.id<>auth.uid() and not exists(select 1 from public.unichat_blocks b where (b.blocker=p.id and b.blocked=auth.uid()) or (b.blocker=auth.uid() and b.blocked=p.id)) loop
  if not public.unichat_post_visible_to(post_id,r.id) then continue;end if;
  insert into public.unichat_tag_events values(auth.uid(),r.id,source_kind,source_id,post_id) on conflict do nothing;get diagnostics inserted=row_count;
  if inserted=1 then insert into public.unichat_notifications(recipient,actor,kind,reference,context) values(r.id,auth.uid(),'mention',post_id,jsonb_build_object('source_kind',source_kind,'source_id',source_id));end if;
 end loop;
end$$;
create or replace function public.unichat_tag_trigger() returns trigger language plpgsql security definer set search_path='' as $$
declare ref text;body text;kind text;begin
 if tg_table_name='unichat_content' then
  if new.kind not in ('post','comment') then return new;end if;
  if tg_op='UPDATE' and new.data->>'text' is not distinct from old.data->>'text' then return new;end if;
  kind:=new.kind;body:=new.data->>'text';ref:=case when new.kind='post' then new.id else new.data->>'postId' end;
 else
  if tg_op='UPDATE' and new.body is not distinct from old.body then return new;end if;
  kind:='reply';body:=new.body;select data->>'postId' into ref from public.unichat_content c where c.id=new.comment_id and c.kind='comment';
 end if;
 perform public.unichat_emit_tags(body,ref,kind,new.id::text);return new;
end$$;
drop trigger if exists uc_tag_notice on public.unichat_content;
create trigger uc_tag_notice after insert or update on public.unichat_content for each row execute function public.unichat_tag_trigger();
drop trigger if exists uc_tag_notice on public.unichat_post_replies;
create trigger uc_tag_notice after insert or update on public.unichat_post_replies for each row execute function public.unichat_tag_trigger();
-- The original trigger still handles follows, comments, replies, DMs, voice and files.
create or replace function public.unichat_notice_trigger() returns trigger language plpgsql security definer set search_path='' as $$declare target uuid;ref text;begin
 if tg_table_name='unichat_follows' then perform public.unichat_notify(new.following,'follow',new.follower::text);
 elsif tg_table_name='unichat_chat_members' then if new.status='pending' then perform public.unichat_notify(new.user_id,'group_invite',new.chat_id::text);end if;
 elsif tg_table_name='unichat_chat_messages' then for target in select user_id from public.unichat_chat_members where chat_id=new.chat_id and status='active' loop perform public.unichat_notify(target,'group_message',new.chat_id::text);end loop;
 elsif tg_table_name='unichat_attachments' then if new.recipient is not null then perform public.unichat_notify(new.recipient,'attachment',new.sender::text);else for target in select user_id from public.unichat_chat_members where chat_id=new.chat_id and status='active' loop perform public.unichat_notify(target,'group_message',new.chat_id::text);end loop;end if;
 elsif tg_table_name='unichat_voice_messages' then perform public.unichat_notify(new.recipient,'voice',new.sender::text);
 elsif tg_table_name='unichat_post_replies' then select owner,data->>'postId' into target,ref from public.unichat_content c where c.id=new.comment_id and c.kind='comment';perform public.unichat_notify(target,'reply',ref);
 elsif tg_table_name='unichat_content' then
  if new.kind='message' then perform public.unichat_notify((new.data->>'recipient')::uuid,'message',new.owner::text);
  elsif new.kind='comment' then select owner into target from public.unichat_content where id=new.data->>'postId';perform public.unichat_notify(target,'comment',new.data->>'postId');
  elsif new.kind='like' then select owner into target from public.unichat_content where id=new.data->>'postId' and kind='post';perform public.unichat_notify(target,'post_like',new.data->>'postId');end if;
 end if;return new;end$$;
create or replace function public.unichat_save_controls(payload jsonb) returns void language plpgsql security definer set search_path='' as $$
declare bucket text;v jsonb;hard_max bigint;allowed text[];types text[];size_limit bigint;merged jsonb;begin
 if not public.unichat_is_owner() then raise exception 'Owner access required';end if;
 if (payload->>'owner_mfa')::boolean is true and coalesce(nullif(current_setting('request.jwt.claims',true),''),'{}')::jsonb->>'aal' is distinct from 'aal2' then raise exception 'Verify your authenticator before requiring MFA';end if;
 merged:=coalesce((select upload_limits from public.unichat_control where id='main'),'{}')||coalesce(payload->'limits','{}');
 for bucket,v in select * from jsonb_each(merged) loop
  select b.file_size_limit,b.allowed_mime_types into hard_max,allowed from (values
   ('unichat-space-photos',5242880::bigint,array['image/jpeg']),
   ('unichat-media',2621440::bigint,array['image/png','image/jpeg','image/webp','image/gif','video/mp4']),
   ('unichat-chat-files',10485760,array['image/jpeg','image/png','image/webp','image/gif','video/mp4','video/webm','application/pdf']),
   ('unichat-social-media',20971520,array['image/jpeg','image/png','image/webp','video/mp4','video/webm']),
   ('unichat-voice',1048576,array['audio/webm','audio/ogg','audio/mp4']),
   ('unichat-avatars',524288,array['image/jpeg','image/png','image/webp']),('unichat-covers',1048576,array['image/jpeg'])
  )b(id,file_size_limit,allowed_mime_types) where b.id=bucket;
  if hard_max is null then raise exception 'Unsupported upload category';end if;
  size_limit:=(v->>'bytes')::bigint;select array_agg(t) into types from jsonb_array_elements_text(v->'types')t;
  if size_limit is null or size_limit<1024 or size_limit>9007199254740991 or coalesce(cardinality(types),0)=0 or not types<@allowed then raise exception 'Invalid upload limit or type';end if;
  if bucket in ('unichat-social-media','unichat-voice') and ((v->>'seconds')::numeric is null or (v->>'seconds')::numeric<1 or (v->>'seconds')::numeric>60) then raise exception 'Video/voice duration must be 1–60 seconds';end if;
  update storage.buckets set file_size_limit=size_limit,allowed_mime_types=types where id=bucket;
 end loop;
 update public.unichat_control set maintenance=coalesce((payload->>'maintenance')::boolean,maintenance),maintenance_message=coalesce(nullif(trim(payload->>'message'),''),maintenance_message),owner_mfa=coalesce((payload->>'owner_mfa')::boolean,owner_mfa),upload_limits=merged where id='main';
end$$;

create or replace function public.unichat_tag_students(search_text text default '') returns table(id uuid,username text,data jsonb) language sql stable security invoker set search_path='' as $$
 select p.id,p.username,jsonb_build_object('name',p.data->>'name','avatar_path',p.data->>'avatar_path') from public.unichat_profiles p where public.unichat_active() and p.status='active' and p.id<>auth.uid() and public.unichat_profile_visible(p.id)
 and not exists(select 1 from public.unichat_blocks b where (b.blocker=auth.uid() and b.blocked=p.id) or (b.blocker=p.id and b.blocked=auth.uid()))
 and (trim(coalesce(search_text,''))='' or position(lower(left(trim(search_text),60)) in lower(concat_ws(' ',p.username,p.data->>'name')))>0)
 order by exists(select 1 from public.unichat_follows f where f.follower=auth.uid() and f.following=p.id) desc,lower(p.data->>'name'),p.id limit 12
$$;
create or replace function public.unichat_notification_page(before_time timestamptz default null,before_id uuid default null,only_unread boolean default false) returns jsonb language sql stable security invoker set search_path='' as $$
 select jsonb_build_object('rows',coalesce((select jsonb_agg(to_jsonb(r) order by r.created_at desc,r.id desc) from (
 select n.*,jsonb_build_object('name',p.data->>'name','username',p.username,'avatar_path',p.data->>'avatar_path') actor_data from public.unichat_notifications n left join public.unichat_profiles p on p.id=n.actor
 where n.recipient=auth.uid() and public.unichat_active() and (not only_unread or n.read_at is null) and (before_time is null or (n.created_at,n.id)<(before_time,before_id)) order by n.created_at desc,n.id desc limit 31)r),'[]'),
 'unread',(select count(*) from public.unichat_notifications where recipient=auth.uid() and read_at is null and public.unichat_active()))
$$;
create or replace function public.unichat_notification_count() returns bigint language sql stable security invoker set search_path='' as $$select count(*) from public.unichat_notifications where recipient=auth.uid() and read_at is null and public.unichat_active()$$;
create or replace function public.unichat_notifications_read_all() returns void language sql security definer set search_path='' as $$update public.unichat_notifications set read_at=now() where recipient=auth.uid() and read_at is null and public.unichat_active()$$;
revoke all on function public.unichat_space_photo_guard(),public.unichat_share_guard(),public.unichat_post_visible_to(text,uuid),public.unichat_emit_tags(text,text,text,text),public.unichat_tag_trigger() from public,anon,authenticated;
revoke all on function public.unichat_space_photo_upload_allowed(text),public.unichat_space_photo_linked(text),public.unichat_tag_students(text),public.unichat_notification_page(timestamptz,uuid,boolean),public.unichat_notification_count(),public.unichat_notifications_read_all() from public,anon;
grant execute on function public.unichat_space_photo_upload_allowed(text),public.unichat_space_photo_linked(text),public.unichat_tag_students(text),public.unichat_notification_page(timestamptz,uuid,boolean),public.unichat_notification_count(),public.unichat_notifications_read_all() to authenticated;
commit;
