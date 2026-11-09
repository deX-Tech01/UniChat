-- Owner operations. Run through the combined upgrade. No private-chat browsing access.
begin;
create table if not exists public.unichat_control(
 id text primary key default 'main' check(id='main'),maintenance boolean not null default false,
 maintenance_message text not null default 'UniChat is receiving an update. Please check back shortly.' check(length(maintenance_message) between 1 and 500),
 owner_mfa boolean not null default false,upload_limits jsonb not null default '{}'::jsonb
);
insert into public.unichat_control(id) values('main') on conflict do nothing;
create table if not exists public.unichat_staff(user_id uuid primary key references public.unichat_profiles(id),role text not null check(role='moderator'),created_at timestamptz not null default now());
create table if not exists public.unichat_audit(id bigint generated always as identity primary key,actor uuid,action text not null,target text not null,details jsonb not null default '{}',created_at timestamptz not null default now());
create table if not exists public.unichat_presence(user_id uuid not null references public.unichat_profiles(id),tab_id uuid not null,last_seen timestamptz not null default now(),primary key(user_id,tab_id));
create table if not exists public.unichat_activity(user_id uuid not null references public.unichat_profiles(id),day date not null,last_seen timestamptz not null default now(),primary key(user_id,day));
create index if not exists uc_presence_seen on public.unichat_presence(last_seen);
create table if not exists public.unichat_announcements(id uuid primary key default gen_random_uuid(),title text not null check(length(trim(title)) between 2 and 150),body text not null check(length(trim(body)) between 2 and 3000),school text not null default '',department text not null default '',published boolean not null default true,starts_at timestamptz not null default now(),ends_at timestamptz,created_at timestamptz not null default now(),check(ends_at is null or ends_at>starts_at));
create table if not exists public.unichat_reports(id uuid primary key default gen_random_uuid(),reporter uuid references public.unichat_profiles(id),target_kind text not null,target_id text not null,reason text not null check(length(reason) between 2 and 100),details text not null default '' check(length(details)<=2000),evidence jsonb not null default '{}',status text not null default 'open' check(status in ('open','reviewing','resolved','dismissed')),resolution text not null default '' check(length(resolution)<=1500),legacy_id text unique,created_at timestamptz not null default now(),resolved_by uuid,resolved_at timestamptz);
create index if not exists uc_reports_queue on public.unichat_reports(status,created_at desc);

create or replace function public.unichat_owner_identity() returns boolean language sql stable security definer set search_path='' as $$select exists(select 1 from auth.users where id=auth.uid() and lower(email)='chimdike247@gmail.com' and email_confirmed_at is not null)$$;
create or replace function public.unichat_is_owner() returns boolean language sql stable security definer set search_path='' as $$select public.unichat_owner_identity() and (not coalesce((select owner_mfa from public.unichat_control where id='main'),false) or coalesce(coalesce(nullif(current_setting('request.jwt.claims',true),''),'{}')::jsonb->>'aal'='aal2',false))$$;
create or replace function public.unichat_site_open() returns boolean language sql stable security definer set search_path='' as $$select public.unichat_is_owner() or not coalesce((select maintenance from public.unichat_control where id='main'),false)$$;
create or replace function public.unichat_active() returns boolean language sql stable security definer set search_path='' as $$select public.unichat_is_owner() or (public.unichat_site_open() and exists(select 1 from public.unichat_profiles where id=auth.uid() and status='active'))$$;
create or replace function public.unichat_permission(capability text) returns boolean language sql stable security definer set search_path='' as $$select public.unichat_is_owner() or (capability='moderate' and public.unichat_active() and exists(select 1 from public.unichat_staff where user_id=auth.uid() and role='moderator'))$$;
create or replace function public.unichat_access_state() returns jsonb language sql stable security definer set search_path='' as $$
 select jsonb_build_object('maintenance',maintenance,'message',maintenance_message,'owner_identity',public.unichat_owner_identity(),'owner',public.unichat_is_owner(),'mfa_required',owner_mfa,'moderator',public.unichat_permission('moderate'),'limits',upload_limits) from public.unichat_control where id='main'
$$;
create or replace function public.unichat_log(action_name text,record_target text,info jsonb default '{}') returns void language sql security definer set search_path='' as $$insert into public.unichat_audit(actor,action,target,details) values(auth.uid(),action_name,record_target,info)$$;
create or replace function public.unichat_audit_change() returns trigger language plpgsql security definer set search_path='' as $$
declare row_data jsonb;begin
 row_data:=case when tg_op='DELETE' then to_jsonb(old) else to_jsonb(new) end;
 if public.unichat_permission('moderate') then
  if tg_table_name='unichat_content' then if row_data->>'kind' not in ('post','comment','report') then return null;end if;end if;
  perform public.unichat_log(lower(tg_op)||':'||tg_table_name,coalesce(row_data->>'id',row_data->>'user_id','settings'),jsonb_build_object('kind',row_data->>'kind'));
 end if;return null;end$$;

create or replace function public.unichat_heartbeat(session_tab uuid,is_visible boolean default true) returns void language plpgsql security definer set search_path='' as $$begin
 if not public.unichat_active() then return;end if;
 if is_visible then
  insert into public.unichat_presence(user_id,tab_id,last_seen) values(auth.uid(),session_tab,now()) on conflict(user_id,tab_id) do update set last_seen=now();
  insert into public.unichat_activity(user_id,day,last_seen) values(auth.uid(),(now() at time zone 'Africa/Lagos')::date,now()) on conflict(user_id,day) do update set last_seen=now();
 else delete from public.unichat_presence where user_id=auth.uid() and tab_id=session_tab;end if;
 delete from public.unichat_presence where last_seen<now()-interval '1 day';
end$$;
create or replace function public.unichat_owner_stats() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare today timestamptz;result jsonb;begin
 if not public.unichat_is_owner() then raise exception 'Owner access required';end if;
 today:=date_trunc('day',now() at time zone 'Africa/Lagos') at time zone 'Africa/Lagos';
 select jsonb_build_object('registered',(select count(*) from auth.users),'profiles',(select count(*) from public.unichat_profiles),'online',(select count(distinct s.user_id) from public.unichat_presence s join public.unichat_profiles p on p.id=s.user_id where s.last_seen>now()-interval '90 seconds' and p.status='active'),'new_today',(select count(*) from auth.users u where coalesce((to_jsonb(u)->>'created_at')::timestamptz,(select created_at from public.unichat_profiles p where p.id=u.id))>=today),'active_today',(select count(*) from public.unichat_activity where day=(now() at time zone 'Africa/Lagos')::date),'suspended',(select count(*) from public.unichat_profiles where status='suspended'),'open_reports',(select count(*) from public.unichat_reports where status in ('open','reviewing')),'by_school',coalesce((select jsonb_agg(v order by (v->>'count')::int desc) from(select jsonb_build_object('school',data->>'school','count',count(*)) v from public.unichat_profiles group by data->>'school')s),'[]'::jsonb),'by_department',coalesce((select jsonb_agg(v order by (v->>'count')::int desc) from(select jsonb_build_object('school',data->>'school','department',data->>'department','count',count(*)) v from public.unichat_profiles group by data->>'school',data->>'department')s),'[]'::jsonb),'growth',coalesce((select jsonb_agg(v order by v->>'day') from(select jsonb_build_object('day',to_char(created_at at time zone 'Africa/Lagos','YYYY-MM-DD'),'count',count(*)) v from public.unichat_profiles where created_at>=now()-interval '30 days' group by to_char(created_at at time zone 'Africa/Lagos','YYYY-MM-DD'))s),'[]'::jsonb)) into result;
 return result;
end$$;
create or replace function public.unichat_owner_users(search_text text default '',page_offset integer default 0) returns jsonb language plpgsql stable security definer set search_path='' as $$begin
 if not public.unichat_permission('moderate') then raise exception 'Moderation access required';end if;
 return coalesce((select jsonb_agg(to_jsonb(p)||jsonb_build_object('online',exists(select 1 from public.unichat_presence s where s.user_id=p.id and s.last_seen>now()-interval '90 seconds'),'reports',(select count(*) from public.unichat_reports r where r.target_kind='profile' and r.target_id=p.id::text))) from(select * from public.unichat_profiles where concat_ws(' ',username,data->>'name',data->>'school',data->>'department') ilike '%'||left(search_text,100)||'%' order by created_at desc,id limit 50 offset greatest(0,least(page_offset,100000)))p),'[]'::jsonb);
end$$;
create or replace function public.unichat_owner_student(student_id uuid,profile_patch jsonb default null,new_status text default null) returns void language plpgsql security definer set search_path='' as $$
begin
 if not public.unichat_permission('moderate') then raise exception 'Moderation access required';end if;
 if exists(select 1 from auth.users where id=student_id and lower(email)='chimdike247@gmail.com') and not public.unichat_is_owner() then raise exception 'Only the owner can edit this account';end if;
 if profile_patch is not null then
  if not public.unichat_is_owner() then raise exception 'Only the owner can edit student details';end if;
  if exists(select 1 from jsonb_object_keys(profile_patch) k where k not in ('name','username','school','department','level','bio')) then raise exception 'Unsupported profile field';end if;
  update public.unichat_profiles set data=data||profile_patch,username=coalesce(lower(profile_patch->>'username'),username) where id=student_id;
 end if;
 if new_status is not null then
  if new_status not in ('active','suspended') then raise exception 'Invalid status';end if;
  if student_id=auth.uid() and new_status='suspended' then raise exception 'Cannot suspend your own account';end if;
  if not public.unichat_is_owner() and exists(select 1 from public.unichat_staff where user_id=student_id) then raise exception 'Only the owner can suspend staff';end if;
  update public.unichat_profiles set status=new_status where id=student_id;
  if new_status='suspended' then delete from public.unichat_presence where user_id=student_id;end if;
 end if;
end$$;

-- The original profile guard permits status changes only by the authorised moderation path.
create or replace function public.unichat_validate_profile() returns trigger language plpgsql security definer set search_path='' as $$begin
 if length(coalesce(new.data->>'name','')) not between 2 and 80 or trim(coalesce(new.data->>'school',''))='' or trim(coalesce(new.data->>'department',''))='' or trim(coalesce(new.data->>'level',''))='' then raise exception 'Complete all required profile fields';end if;
 new.username:=lower(new.username);new.data:=new.data||jsonb_build_object('username',new.username);
 if tg_op='INSERT' then
  if not public.unichat_site_open() or (not public.unichat_feature('registration') and not public.unichat_is_owner()) then raise exception 'Registration is paused';end if;
  if not public.unichat_is_owner() then new.status:='active';end if;
 else
  if new.id<>old.id then raise exception 'Profile identity cannot change';end if;
  if new.status<>old.status and not public.unichat_permission('moderate') then raise exception 'Moderation access required';end if;
  if new.id=auth.uid() and public.unichat_owner_identity() and new.status='suspended' then raise exception 'Owner cannot suspend own account';end if;
 end if;return new;
end$$;

create or replace function public.unichat_set_staff(student_id uuid,enabled boolean) returns void language plpgsql security definer set search_path='' as $$begin
 if not public.unichat_is_owner() then raise exception 'Owner access required';end if;
 if exists(select 1 from auth.users where id=student_id and lower(email)='chimdike247@gmail.com') then raise exception 'The owner role is fixed';end if;
 if enabled then insert into public.unichat_staff(user_id,role) select id,'moderator' from public.unichat_profiles where id=student_id and status='active' on conflict(user_id) do nothing;else delete from public.unichat_staff where user_id=student_id;end if;
end$$;

create or replace function public.unichat_save_controls(payload jsonb) returns void language plpgsql security definer set search_path='' as $$
declare bucket text;v jsonb;hard_max bigint;allowed text[];types text[];size_limit bigint;merged jsonb;begin
 if not public.unichat_is_owner() then raise exception 'Owner access required';end if;
 if (payload->>'owner_mfa')::boolean is true and coalesce(nullif(current_setting('request.jwt.claims',true),''),'{}')::jsonb->>'aal' is distinct from 'aal2' then raise exception 'Verify your authenticator before requiring MFA';end if;
 merged:=coalesce((select upload_limits from public.unichat_control where id='main'),'{}')||coalesce(payload->'limits','{}');
 for bucket,v in select * from jsonb_each(merged) loop
  select b.file_size_limit,b.allowed_mime_types into hard_max,allowed from (values
   ('unichat-media',2621440::bigint,array['image/png','image/jpeg','image/webp','image/gif','video/mp4']),
   ('unichat-chat-files',10485760,array['image/jpeg','image/png','image/webp','image/gif','video/mp4','video/webm','application/pdf']),
   ('unichat-social-media',20971520,array['image/jpeg','image/png','image/webp','video/mp4','video/webm']),
   ('unichat-voice',1048576,array['audio/webm','audio/ogg','audio/mp4']),
   ('unichat-avatars',524288,array['image/jpeg','image/png','image/webp']),('unichat-covers',1048576,array['image/jpeg'])
  )b(id,file_size_limit,allowed_mime_types) where b.id=bucket;
  if hard_max is null then raise exception 'Unsupported upload category';end if;
  size_limit:=(v->>'bytes')::bigint;select array_agg(t) into types from jsonb_array_elements_text(v->'types')t;
  if size_limit is null or size_limit<1024 or size_limit>hard_max or coalesce(cardinality(types),0)=0 or not types<@allowed then raise exception 'Invalid upload limit or type';end if;
  if bucket in ('unichat-social-media','unichat-voice') and ((v->>'seconds')::numeric is null or (v->>'seconds')::numeric<1 or (v->>'seconds')::numeric>60) then raise exception 'Video/voice duration must be 1–60 seconds';end if;
  update storage.buckets set file_size_limit=size_limit,allowed_mime_types=types where id=bucket;
 end loop;
 update public.unichat_control set maintenance=coalesce((payload->>'maintenance')::boolean,maintenance),maintenance_message=coalesce(nullif(trim(payload->>'message'),''),maintenance_message),owner_mfa=coalesce((payload->>'owner_mfa')::boolean,owner_mfa),upload_limits=merged where id='main';
end$$;
create or replace function public.unichat_duration_limit(bucket text) returns numeric language sql stable security definer set search_path='' as $$select coalesce((upload_limits->bucket->>'seconds')::numeric,60) from public.unichat_control where id='main'$$;
create or replace function public.unichat_media_duration_guard() returns trigger language plpgsql security definer set search_path='' as $$begin
 if new.duration_seconds>public.unichat_duration_limit(case when tg_table_name='unichat_media' then 'unichat-social-media' else 'unichat-voice' end) then raise exception 'This recording exceeds the owner duration limit';end if;return new;
end$$;
drop trigger if exists uc_owner_media_duration on public.unichat_media;create trigger uc_owner_media_duration before insert on public.unichat_media for each row execute function public.unichat_media_duration_guard();
drop trigger if exists uc_owner_voice_duration on public.unichat_voice_messages;create trigger uc_owner_voice_duration before insert on public.unichat_voice_messages for each row execute function public.unichat_media_duration_guard();

create or replace function public.unichat_owner_feature_guard() returns trigger language plpgsql security definer set search_path='' as $$
declare capability text;row_data jsonb;begin
 row_data:=to_jsonb(new);
 capability:=case tg_table_name when 'unichat_listings' then case when row_data->>'kind'='opportunity' then 'opportunities' else 'marketplace' end when 'unichat_follows' then 'following' when 'unichat_post_replies' then 'comments' when 'unichat_reel_comments' then 'comments' when 'unichat_chats' then 'groups' when 'unichat_chat_members' then 'groups' when 'unichat_chat_messages' then 'groups' else null end;
 if tg_table_name='unichat_content' then if row_data->>'kind'='comment' then capability:='comments';elsif row_data->>'kind'='like' then capability:='reactions';end if;end if;
 if tg_table_name='unichat_attachments' then if row_data->>'chat_id' is not null then capability:='groups';end if;end if;
 if capability is not null and not public.unichat_feature(capability) and not public.unichat_is_owner() then raise exception '% is currently paused',capability;end if;return new;
end$$;
do $$declare t text;begin foreach t in array array['unichat_listings','unichat_follows','unichat_post_replies','unichat_reel_comments','unichat_chats','unichat_chat_members','unichat_chat_messages','unichat_attachments','unichat_content'] loop execute format('drop trigger if exists uc_owner_feature_guard on public.%I',t);execute format('create trigger uc_owner_feature_guard before insert on public.%I for each row execute function public.unichat_owner_feature_guard()',t);end loop;end$$;
revoke all on function public.unichat_owner_feature_guard() from public,anon,authenticated;

create or replace function public.unichat_submit_report(kind_name text,record_id text,report_reason text,report_details text default '') returns uuid language plpgsql security definer set search_path='' as $$
declare snapshot jsonb;new_id uuid;begin
 if not public.unichat_active() then raise exception 'Sign in with an active account';end if;
 if (select count(*) from public.unichat_reports where reporter=auth.uid() and created_at>now()-interval '1 hour')>=20 then raise exception 'Please wait before sending more reports';end if;
 if kind_name in ('post','comment') then select to_jsonb(c) into snapshot from public.unichat_content c where id=record_id and kind=kind_name;
 elsif kind_name='reply' then select to_jsonb(r) into snapshot from public.unichat_post_replies r where id::text=record_id;
 elsif kind_name='reel_comment' then select to_jsonb(c) into snapshot from public.unichat_reel_comments c where id::text=record_id and public.unichat_media_visible(c.reel_id);
 elsif kind_name='profile' then select jsonb_build_object('id',id,'username',username,'data',data) into snapshot from public.unichat_profiles where id::text=record_id;
 elsif kind_name in ('reel','story') then select to_jsonb(m)||jsonb_build_object('bucket','unichat-social-media') into snapshot from public.unichat_media m where id::text=record_id and kind=kind_name and public.unichat_media_visible(id);
 elsif kind_name='listing' then select to_jsonb(l) into snapshot from public.unichat_listings l where id::text=record_id;
 elsif kind_name='discussion' then select to_jsonb(d) into snapshot from public.unichat_discussions d where id::text=record_id and exists(select 1 from public.unichat_memberships where community_id=d.community_id and user_id=auth.uid());
 elsif kind_name='message' then select to_jsonb(c) into snapshot from public.unichat_content c where id=record_id and kind='message' and (owner=auth.uid() or data->>'recipient'=auth.uid()::text);
 elsif kind_name='voice' then select to_jsonb(v)||jsonb_build_object('bucket','unichat-voice') into snapshot from public.unichat_voice_messages v where id::text=record_id and (sender=auth.uid() or recipient=auth.uid());
 elsif kind_name='attachment' then select to_jsonb(a)||jsonb_build_object('bucket','unichat-chat-files') into snapshot from public.unichat_attachments a where id::text=record_id and (sender=auth.uid() or recipient=auth.uid() or public.unichat_group_member(chat_id));
 elsif kind_name='group_message' then select to_jsonb(m) into snapshot from public.unichat_chat_messages m where id::text=record_id and public.unichat_group_member(chat_id);
 else raise exception 'Unsupported report type';end if;
 if snapshot is null then raise exception 'This item is unavailable or is not part of your conversation';end if;
 insert into public.unichat_reports(reporter,target_kind,target_id,reason,details,evidence) values(auth.uid(),kind_name,record_id,report_reason,report_details,snapshot) returning id into new_id;return new_id;
end$$;
create or replace function public.unichat_review_report(report_id uuid,new_status text,note text default '') returns void language plpgsql security definer set search_path='' as $$begin
 if not public.unichat_permission('moderate') then raise exception 'Moderation access required';end if;
 update public.unichat_reports set status=new_status,resolution=note,resolved_by=auth.uid(),resolved_at=case when new_status in ('resolved','dismissed') then now() else null end where id=report_id;
end$$;
create or replace function public.unichat_report_file(bucket_name text,object_name text) returns boolean language sql stable security definer set search_path='' as $$select public.unichat_permission('moderate') and exists(select 1 from public.unichat_reports where target_kind in ('voice','attachment','reel','story') and evidence->>'bucket'=bucket_name and evidence->>'storage_path'=object_name)$$;
drop policy if exists uc_reported_file_read on storage.objects;create policy uc_reported_file_read on storage.objects for select to authenticated using(public.unichat_report_file(bucket_id,name));
create or replace function public.unichat_evidence_held(bucket_name text,object_name text) returns boolean language sql stable security definer set search_path='' as $$select exists(select 1 from public.unichat_reports r where status in ('open','reviewing') and ((r.evidence->>'bucket'=bucket_name and r.evidence->>'storage_path'=object_name) or (bucket_name='unichat-media' and r.evidence->'data'->>'media_path'=object_name)))$$;
drop policy if exists uc_hold_reported_evidence on storage.objects;create policy uc_hold_reported_evidence on storage.objects as restrictive for delete to authenticated using(not public.unichat_evidence_held(bucket_id,name));
revoke all on function public.unichat_evidence_held(text,text) from public,anon;
grant execute on function public.unichat_evidence_held(text,text) to authenticated;

create or replace function public.unichat_moderate(kind_name text,record_id text,decision text,replacement text default '') returns void language plpgsql security definer set search_path='' as $$begin
 if not public.unichat_permission('moderate') then raise exception 'Moderation access required';end if;
 if decision not in ('remove','edit') then raise exception 'Unsupported decision';end if;
 if kind_name='post' then
  if decision='edit' then update public.unichat_content set data=data||jsonb_build_object('text',replacement) where id=record_id and kind='post';else
   delete from public.unichat_post_replies where comment_id in (select id from public.unichat_content where kind='comment' and data->>'postId'=record_id);
   delete from public.unichat_content where kind in ('like','comment') and data->>'postId'=record_id;
   delete from public.unichat_content where id=record_id and kind='post';end if;
 elsif kind_name='comment' then if decision='edit' then raise exception 'Remove the comment instead';end if;delete from public.unichat_post_replies where comment_id=record_id;delete from public.unichat_content where id=record_id and kind='comment';
 elsif kind_name='reply' then delete from public.unichat_post_replies where id::text=record_id;
 elsif kind_name='reel_comment' then delete from public.unichat_reel_comments where id::text=record_id;
 elsif kind_name in ('reel','story') then if decision='edit' then update public.unichat_media set caption=replacement where id::text=record_id and kind=kind_name;else delete from public.unichat_media where id::text=record_id and kind=kind_name;end if;
 elsif kind_name='listing' then if decision='edit' then update public.unichat_listings set body=replacement where id::text=record_id;else update public.unichat_listings set status='closed' where id::text=record_id;end if;
 elsif kind_name='discussion' then if decision='edit' then update public.unichat_discussions set body=replacement where id::text=record_id;else delete from public.unichat_discussions where id::text=record_id;end if;
 else raise exception 'Use suspension for private-chat abuse; private messages cannot be browsed or edited here';end if;
 perform public.unichat_log('moderate:'||decision,kind_name||':'||record_id);
end$$;

create or replace function public.unichat_storage_overview() returns jsonb language plpgsql stable security definer set search_path='' as $$begin
 if not public.unichat_is_owner() then raise exception 'Owner access required';end if;
 return coalesce((select jsonb_agg(s) from(select bucket_id,count(*) files,coalesce(sum(coalesce((to_jsonb(o)->'metadata'->>'size')::bigint,0)),0) bytes from storage.objects o where bucket_id like 'unichat-%' group by bucket_id)s),'[]'::jsonb);
end$$;
create or replace function public.unichat_cleanup_candidates() returns jsonb language plpgsql stable security definer set search_path='' as $$begin
 if not public.unichat_is_owner() then raise exception 'Owner access required';end if;
 return coalesce((select jsonb_agg(r) from(select bucket_id,name from storage.objects o where (
 (bucket_id='unichat-social-media' and (exists(select 1 from public.unichat_media m where m.storage_path=o.name and m.kind='story' and m.expires_at<=now()) or (not exists(select 1 from public.unichat_media m where m.storage_path=o.name) and coalesce((to_jsonb(o)->>'created_at')::timestamptz,now())<now()-interval '1 day')))
 or (bucket_id='unichat-covers' and not exists(select 1 from public.unichat_profiles p where p.data->>'cover_path'=o.name) and coalesce((to_jsonb(o)->>'created_at')::timestamptz,now())<now()-interval '1 day')
 or (bucket_id='unichat-avatars' and not exists(select 1 from public.unichat_profiles p where p.data->>'avatar_path'=o.name) and coalesce((to_jsonb(o)->>'created_at')::timestamptz,now())<now()-interval '1 day')
 or (bucket_id='unichat-media' and not exists(select 1 from public.unichat_content c where kind='post' and data->>'media_path'=o.name) and coalesce((to_jsonb(o)->>'created_at')::timestamptz,now())<now()-interval '1 day'))
 and not exists(select 1 from public.unichat_reports r where status in ('open','reviewing') and ((r.evidence->>'bucket'=o.bucket_id and r.evidence->>'storage_path'=o.name) or (o.bucket_id='unichat-media' and r.evidence->'data'->>'media_path'=o.name))) limit 100)r),'[]'::jsonb);
end$$;
create or replace function public.unichat_cleanup_allowed(bucket_name text,object_name text) returns boolean language plpgsql stable security definer set search_path='' as $$begin if not public.unichat_is_owner() then return false;end if;return exists(select 1 from jsonb_array_elements(public.unichat_cleanup_candidates()) c where c->>'bucket_id'=bucket_name and c->>'name'=object_name);end$$;
drop policy if exists uc_owner_cleanup_read on storage.objects;create policy uc_owner_cleanup_read on storage.objects for select to authenticated using(public.unichat_cleanup_allowed(bucket_id,name));
drop policy if exists uc_owner_cleanup_remove on storage.objects;create policy uc_owner_cleanup_remove on storage.objects for delete to authenticated using(public.unichat_cleanup_allowed(bucket_id,name));
create or replace function public.unichat_cleanup_finished() returns void language plpgsql security definer set search_path='' as $$begin
 if not public.unichat_is_owner() then raise exception 'Owner access required';end if;
 delete from public.unichat_media m where kind='story' and expires_at<=now() and not exists(select 1 from storage.objects where bucket_id='unichat-social-media' and name=m.storage_path);
 perform public.unichat_log('storage:cleanup','expired Stories and unused profile files');
end$$;

create or replace function public.unichat_export_public() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb;t text;rows jsonb;begin
 if not public.unichat_is_owner() then raise exception 'Owner access required';end if;
 result:=jsonb_build_object('format','unichat-public-export-v1','exported_at',now());
 foreach t in array array['profiles','settings','directory','communities','events','media','listings','announcements'] loop execute format('select coalesce(jsonb_agg(to_jsonb(t)),''[]''::jsonb) from public.%I t','unichat_'||t) into rows;result:=result||jsonb_build_object(t,rows);end loop;
 result:=result||jsonb_build_object('content',coalesce((select jsonb_agg(to_jsonb(c)) from public.unichat_content c where kind in ('post','comment','like')),'[]'::jsonb));
 return result;
end$$;

-- Access and administrative writes are kept behind RLS/RPC checks.
do $$declare t text;begin foreach t in array array['control','staff','audit','presence','activity','announcements','reports'] loop execute format('alter table public.%I enable row level security','unichat_'||t);end loop;end$$;
drop policy if exists uc_control_owner_read on public.unichat_control;create policy uc_control_owner_read on public.unichat_control for select to authenticated using(public.unichat_is_owner());
drop policy if exists uc_staff_owner_read on public.unichat_staff;create policy uc_staff_owner_read on public.unichat_staff for select to authenticated using(public.unichat_is_owner());
drop policy if exists uc_audit_owner_read on public.unichat_audit;create policy uc_audit_owner_read on public.unichat_audit for select to authenticated using(public.unichat_is_owner());
drop policy if exists uc_reports_read on public.unichat_reports;create policy uc_reports_read on public.unichat_reports for select to authenticated using(public.unichat_permission('moderate') or (public.unichat_active() and reporter=auth.uid()));
drop policy if exists uc_announcements_read on public.unichat_announcements;create policy uc_announcements_read on public.unichat_announcements for select to authenticated using(public.unichat_is_owner() or (public.unichat_active() and published and starts_at<=now() and (ends_at is null or ends_at>now()) and (school='' or school=(select data->>'school' from public.unichat_profiles where id=auth.uid())) and (department='' or department=(select data->>'department' from public.unichat_profiles where id=auth.uid()))));
drop policy if exists uc_announcements_owner on public.unichat_announcements;create policy uc_announcements_owner on public.unichat_announcements for all to authenticated using(public.unichat_is_owner()) with check(public.unichat_is_owner());
grant select on public.unichat_control,public.unichat_staff,public.unichat_audit,public.unichat_reports to authenticated;
grant select,insert,update,delete on public.unichat_announcements to authenticated;

-- Do not let maintenance be bypassed through an old write policy or an RPC.
do $$declare t text;begin foreach t in array array['content','follows','chats','chat_members','chat_messages','attachments','post_replies','listings','communities','memberships','discussions','events','rsvps','contacts','blocks','voice_messages','media','reel_likes','reel_comments'] loop
 execute format('drop policy if exists uc_owner_maintenance on public.%I','unichat_'||t);
 execute format('create policy uc_owner_maintenance on public.%I as restrictive for all to authenticated using(public.unichat_site_open()) with check(public.unichat_site_open())','unichat_'||t);
end loop;end$$;
drop policy if exists uc_profile_maintenance on public.unichat_profiles;create policy uc_profile_maintenance on public.unichat_profiles as restrictive for all to authenticated using(public.unichat_site_open() or id=auth.uid()) with check(public.unichat_site_open());

create or replace function public.unichat_legacy_report() returns trigger language plpgsql security definer set search_path='' as $$begin
 if new.kind='report' then insert into public.unichat_reports(reporter,target_kind,target_id,reason,evidence,legacy_id,created_at) values(new.owner,'post',coalesce(new.data->>'postId',''),coalesce(nullif(new.data->>'reason',''),'Legacy report'),jsonb_build_object('legacy_report',new.data),new.id,new.created_at) on conflict(legacy_id) do nothing;end if;return new;
end$$;
drop trigger if exists uc_legacy_report on public.unichat_content;create trigger uc_legacy_report after insert on public.unichat_content for each row execute function public.unichat_legacy_report();
revoke all on function public.unichat_legacy_report() from public,anon,authenticated;

-- Import existing reports once without exposing private conversations.
insert into public.unichat_reports(reporter,target_kind,target_id,reason,evidence,legacy_id,created_at)
 select c.owner,'post',coalesce(c.data->>'postId',''),coalesce(nullif(c.data->>'reason',''),'Legacy report'),jsonb_build_object('legacy_report',c.data),c.id,c.created_at from public.unichat_content c where c.kind='report' on conflict(legacy_id) do nothing;

do $$declare t text;begin foreach t in array array['control','staff','settings','profiles','directory','announcements','reports','communities','events','discussions','listings','media','content'] loop
 execute format('drop trigger if exists uc_owner_audit on public.%I','unichat_'||t);
 execute format('create trigger uc_owner_audit after insert or update or delete on public.%I for each row execute function public.unichat_audit_change()','unichat_'||t);
end loop;end$$;
revoke all on function public.unichat_log(text,text,jsonb),public.unichat_audit_change(),public.unichat_media_duration_guard() from public,anon,authenticated;
do $$declare signature text;begin foreach signature in array array[
 'unichat_owner_identity()','unichat_site_open()','unichat_permission(text)','unichat_access_state()','unichat_heartbeat(uuid,boolean)','unichat_owner_stats()','unichat_owner_users(text,integer)','unichat_owner_student(uuid,jsonb,text)','unichat_set_staff(uuid,boolean)','unichat_save_controls(jsonb)','unichat_duration_limit(text)','unichat_submit_report(text,text,text,text)','unichat_review_report(uuid,text,text)','unichat_report_file(text,text)','unichat_moderate(text,text,text,text)','unichat_storage_overview()','unichat_cleanup_candidates()','unichat_cleanup_allowed(text,text)','unichat_cleanup_finished()','unichat_export_public()'] loop
 execute 'revoke all on function public.'||signature||' from public,anon';execute 'grant execute on function public.'||signature||' to authenticated';end loop;end$$;
grant execute on function public.unichat_site_open(),public.unichat_access_state() to anon;
do $$declare t text;begin foreach t in array array['unichat_control','unichat_announcements'] loop if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename=t) then execute format('alter publication supabase_realtime add table public.%I',t);end if;end loop;end$$;
-- Preserve configured bucket limits when the combined upgrade is rerun.
do $$declare bucket text;v jsonb;begin for bucket,v in select * from jsonb_each((select upload_limits from public.unichat_control where id='main')) loop update storage.buckets set file_size_limit=(v->>'bytes')::bigint,allowed_mime_types=array(select jsonb_array_elements_text(v->'types')) where id=bucket;end loop;end$$;
commit;
