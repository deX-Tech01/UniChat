-- UniChat combined upgrade 02–12. Run after original Setup. Safe to rerun.
begin;

-- UniChat_Update_02.sql
-- UniChat update 02: communities, events, message requests and blocking.
-- Apply AFTER UniChat_Setup.sql. Existing profiles, posts and branding stay intact.
create table if not exists public.unichat_communities (
 id uuid primary key default gen_random_uuid(), creator uuid not null references public.unichat_profiles(id),
 name text not null check(length(trim(name)) between 2 and 80),
 description text not null default '' check(length(description)<=1500),
 school text not null default 'Across schools' check(length(school)<=150),
 archived boolean not null default false, created_at timestamptz not null default now()
);
create table if not exists public.unichat_memberships (
 community_id uuid not null references public.unichat_communities(id) on delete cascade,
 user_id uuid not null references public.unichat_profiles(id) on delete cascade,
 created_at timestamptz not null default now(),primary key(community_id,user_id)
);
create table if not exists public.unichat_discussions (
 id uuid primary key default gen_random_uuid(),community_id uuid not null references public.unichat_communities(id) on delete cascade,
 author uuid not null references public.unichat_profiles(id),body text not null check(length(trim(body)) between 1 and 3000),
 created_at timestamptz not null default now()
);
create index if not exists unichat_discussions_community_date on public.unichat_discussions(community_id,created_at desc);
create table if not exists public.unichat_events (
 id uuid primary key default gen_random_uuid(),creator uuid not null references public.unichat_profiles(id),
 title text not null check(length(trim(title)) between 2 and 100),
 description text not null default '' check(length(description)<=2000),
 venue text not null check(length(trim(venue)) between 2 and 200),school text not null default 'Across schools' check(length(school)<=150),
 starts_at timestamptz not null,archived boolean not null default false,created_at timestamptz not null default now()
);
create table if not exists public.unichat_rsvps (
 event_id uuid not null references public.unichat_events(id) on delete cascade,user_id uuid not null references public.unichat_profiles(id) on delete cascade,
 status text not null check(status in ('interested','going')),created_at timestamptz not null default now(),primary key(event_id,user_id)
);
create table if not exists public.unichat_contacts (
 id uuid primary key default gen_random_uuid(),sender uuid not null references public.unichat_profiles(id),recipient uuid not null references public.unichat_profiles(id),
 status text not null default 'pending' check(status in ('pending','accepted','declined')),
 created_at timestamptz not null default now(),check(sender<>recipient)
);
create unique index if not exists unichat_contacts_pair on public.unichat_contacts(least(sender,recipient),greatest(sender,recipient));
create table if not exists public.unichat_blocks (
 blocker uuid not null references public.unichat_profiles(id) on delete cascade,blocked uuid not null references public.unichat_profiles(id) on delete cascade,
 created_at timestamptz not null default now(),primary key(blocker,blocked),check(blocker<>blocked)
);

create or replace function public.unichat_member(group_id uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.unichat_memberships where community_id=group_id and user_id=auth.uid())
$$;
create or replace function public.unichat_peer_available(peer uuid) returns boolean language sql stable security definer set search_path='' as $$
 select auth.uid() is not null and auth.uid()<>peer and public.unichat_active()
 and exists(select 1 from public.unichat_profiles where id=peer and status='active')
 and not exists(select 1 from public.unichat_blocks where (blocker=auth.uid() and blocked=peer) or (blocker=peer and blocked=auth.uid()))
$$;
create or replace function public.unichat_can_contact(peer uuid) returns boolean language sql stable security definer set search_path='' as $$
 select public.unichat_peer_available(peer) and exists(select 1 from public.unichat_contacts where status='accepted' and ((sender=auth.uid() and recipient=peer) or (recipient=auth.uid() and sender=peer)))
$$;

create or replace function public.unichat_guard_catalogue() returns trigger language plpgsql security definer set search_path='' as $$
 begin
 if tg_op='UPDATE' then
  if new.id<>old.id or new.creator<>old.creator or new.created_at<>old.created_at then raise exception 'Record identity cannot change';end if;
 end if;
 return new;end $$;
drop trigger if exists unichat_guard_catalogue on public.unichat_communities;
create trigger unichat_guard_catalogue before update on public.unichat_communities for each row execute function public.unichat_guard_catalogue();
drop trigger if exists unichat_guard_catalogue on public.unichat_events;
create trigger unichat_guard_catalogue before update on public.unichat_events for each row execute function public.unichat_guard_catalogue();

create or replace function public.unichat_guard_discussion() returns trigger language plpgsql security definer set search_path='' as $$
 begin
 if new.id<>old.id or new.community_id<>old.community_id or new.author<>old.author or new.created_at<>old.created_at then raise exception 'Discussion identity cannot change';end if;
 return new;end $$;
drop trigger if exists unichat_guard_discussion on public.unichat_discussions;
create trigger unichat_guard_discussion before update on public.unichat_discussions for each row execute function public.unichat_guard_discussion();

create or replace function public.unichat_guard_contact() returns trigger language plpgsql security definer set search_path='' as $$
 begin
 if tg_op='INSERT' then
  if new.sender<>auth.uid() or new.status<>'pending' or not public.unichat_peer_available(new.recipient) then raise exception 'Unable to send this request';end if;
 else
  if new.id<>old.id or new.sender<>old.sender or new.recipient<>old.recipient or new.created_at<>old.created_at then raise exception 'Request identity cannot change';end if;
  if auth.uid()<>old.recipient or new.status not in ('accepted','declined') or not public.unichat_peer_available(old.sender) then raise exception 'Only the recipient can accept or decline a request';end if;
 end if;
 return new;end $$;
drop trigger if exists unichat_guard_contact on public.unichat_contacts;
create trigger unichat_guard_contact before insert or update on public.unichat_contacts for each row execute function public.unichat_guard_contact();

create or replace function public.unichat_guard_message_permissions() returns trigger language plpgsql security definer set search_path='' as $$
 begin
 if new.kind='message' then
  if new.owner<>auth.uid() or not public.unichat_can_contact((new.data->>'recipient')::uuid) then
   raise exception 'Messaging is unavailable. A request must be accepted and neither student may block the other.';
  end if;
 end if;return new;end $$;
drop trigger if exists unichat_guard_message_permissions on public.unichat_content;
create trigger unichat_guard_message_permissions before insert on public.unichat_content for each row execute function public.unichat_guard_message_permissions();

create or replace function public.unichat_guard_rsvp() returns trigger language plpgsql security definer set search_path='' as $$
 begin if new.event_id<>old.event_id or new.user_id<>old.user_id or new.created_at<>old.created_at then raise exception 'RSVP identity cannot change';end if;return new;end $$;
drop trigger if exists unichat_guard_rsvp on public.unichat_rsvps;
create trigger unichat_guard_rsvp before update on public.unichat_rsvps for each row execute function public.unichat_guard_rsvp();
revoke all on function public.unichat_guard_rsvp() from public,anon,authenticated;
alter table public.unichat_communities enable row level security;
alter table public.unichat_memberships enable row level security;
alter table public.unichat_discussions enable row level security;
alter table public.unichat_events enable row level security;
alter table public.unichat_rsvps enable row level security;
alter table public.unichat_contacts enable row level security;
alter table public.unichat_blocks enable row level security;

drop policy if exists uc_groups_read on public.unichat_communities;
create policy uc_groups_read on public.unichat_communities for select to authenticated using(public.unichat_active() and (not archived or creator=auth.uid() or public.unichat_is_owner()));
drop policy if exists uc_groups_create on public.unichat_communities;
create policy uc_groups_create on public.unichat_communities for insert to authenticated with check(public.unichat_active() and public.unichat_feature('communities') and creator=auth.uid());
drop policy if exists uc_groups_edit on public.unichat_communities;
create policy uc_groups_edit on public.unichat_communities for update to authenticated using(public.unichat_active() and (creator=auth.uid() or public.unichat_is_owner())) with check(public.unichat_active() and (creator=auth.uid() or public.unichat_is_owner()));

drop policy if exists uc_members_read on public.unichat_memberships;
create policy uc_members_read on public.unichat_memberships for select to authenticated using(public.unichat_active());
drop policy if exists uc_members_join on public.unichat_memberships;
create policy uc_members_join on public.unichat_memberships for insert to authenticated with check(public.unichat_active() and public.unichat_feature('communities') and user_id=auth.uid() and exists(select 1 from public.unichat_communities where id=community_id and not archived));
drop policy if exists uc_members_leave on public.unichat_memberships;
create policy uc_members_leave on public.unichat_memberships for delete to authenticated using(public.unichat_active() and user_id=auth.uid());

drop policy if exists uc_discussions_read on public.unichat_discussions;
create policy uc_discussions_read on public.unichat_discussions for select to authenticated using(public.unichat_active() and (public.unichat_is_owner() or (public.unichat_member(community_id) and exists(select 1 from public.unichat_communities where id=community_id and not archived))));
drop policy if exists uc_discussions_create on public.unichat_discussions;
create policy uc_discussions_create on public.unichat_discussions for insert to authenticated with check(public.unichat_active() and public.unichat_feature('communities') and author=auth.uid() and public.unichat_member(community_id) and exists(select 1 from public.unichat_communities where id=community_id and not archived));
drop policy if exists uc_discussions_edit on public.unichat_discussions;
create policy uc_discussions_edit on public.unichat_discussions for update to authenticated using(public.unichat_active() and (author=auth.uid() or public.unichat_is_owner())) with check(public.unichat_active() and (author=auth.uid() or public.unichat_is_owner()));
drop policy if exists uc_discussions_delete on public.unichat_discussions;
create policy uc_discussions_delete on public.unichat_discussions for delete to authenticated using(public.unichat_active() and (author=auth.uid() or public.unichat_is_owner()));

drop policy if exists uc_events_read on public.unichat_events;
create policy uc_events_read on public.unichat_events for select to authenticated using(public.unichat_active() and (not archived or creator=auth.uid() or public.unichat_is_owner()));
drop policy if exists uc_events_create on public.unichat_events;
create policy uc_events_create on public.unichat_events for insert to authenticated with check(public.unichat_active() and public.unichat_feature('events') and creator=auth.uid());
drop policy if exists uc_events_edit on public.unichat_events;
create policy uc_events_edit on public.unichat_events for update to authenticated using(public.unichat_active() and (creator=auth.uid() or public.unichat_is_owner())) with check(public.unichat_active() and (creator=auth.uid() or public.unichat_is_owner()));

drop policy if exists uc_rsvps_read on public.unichat_rsvps;
create policy uc_rsvps_read on public.unichat_rsvps for select to authenticated using(public.unichat_active());
drop policy if exists uc_rsvps_create on public.unichat_rsvps;
create policy uc_rsvps_create on public.unichat_rsvps for insert to authenticated with check(public.unichat_active() and public.unichat_feature('events') and user_id=auth.uid() and exists(select 1 from public.unichat_events where id=event_id and not archived));
drop policy if exists uc_rsvps_edit on public.unichat_rsvps;
create policy uc_rsvps_edit on public.unichat_rsvps for update to authenticated using(public.unichat_active() and user_id=auth.uid()) with check(public.unichat_active() and public.unichat_feature('events') and user_id=auth.uid() and exists(select 1 from public.unichat_events where id=event_id and not archived));
drop policy if exists uc_rsvps_remove on public.unichat_rsvps;
create policy uc_rsvps_remove on public.unichat_rsvps for delete to authenticated using(public.unichat_active() and user_id=auth.uid());

drop policy if exists uc_contacts_read on public.unichat_contacts;
create policy uc_contacts_read on public.unichat_contacts for select to authenticated using(public.unichat_active() and (sender=auth.uid() or recipient=auth.uid()));
drop policy if exists uc_contacts_create on public.unichat_contacts;
create policy uc_contacts_create on public.unichat_contacts for insert to authenticated with check(public.unichat_active() and public.unichat_feature('messaging') and sender=auth.uid() and status='pending' and public.unichat_peer_available(recipient));
drop policy if exists uc_contacts_decide on public.unichat_contacts;
create policy uc_contacts_decide on public.unichat_contacts for update to authenticated using(public.unichat_active() and recipient=auth.uid()) with check(public.unichat_active() and recipient=auth.uid() and status in ('accepted','declined'));
drop policy if exists uc_contacts_cancel on public.unichat_contacts;
create policy uc_contacts_cancel on public.unichat_contacts for delete to authenticated using(public.unichat_active() and (sender=auth.uid() or recipient=auth.uid()));

drop policy if exists uc_blocks_read on public.unichat_blocks;
create policy uc_blocks_read on public.unichat_blocks for select to authenticated using(blocker=auth.uid());
drop policy if exists uc_blocks_add on public.unichat_blocks;
create policy uc_blocks_add on public.unichat_blocks for insert to authenticated with check(public.unichat_active() and blocker=auth.uid());
drop policy if exists uc_blocks_remove on public.unichat_blocks;
create policy uc_blocks_remove on public.unichat_blocks for delete to authenticated using(blocker=auth.uid());

grant select,insert,update on public.unichat_communities,public.unichat_events to authenticated;
grant select,insert,delete on public.unichat_memberships,public.unichat_blocks to authenticated;
grant select,insert,update,delete on public.unichat_discussions,public.unichat_rsvps,public.unichat_contacts to authenticated;
revoke all on function public.unichat_guard_catalogue(),public.unichat_guard_discussion(),public.unichat_guard_contact(),public.unichat_guard_message_permissions() from public,anon,authenticated;
revoke all on function public.unichat_member(uuid),public.unichat_peer_available(uuid),public.unichat_can_contact(uuid) from public,anon;
grant execute on function public.unichat_member(uuid),public.unichat_peer_available(uuid),public.unichat_can_contact(uuid) to authenticated;

do $$declare t text;begin
 foreach t in array array['unichat_communities','unichat_memberships','unichat_discussions','unichat_events','unichat_rsvps','unichat_contacts','unichat_blocks'] loop
  if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename=t) then
   execute format('alter publication supabase_realtime add table public.%I',t);
  end if;
 end loop;
end$$;

-- UniChat_Update_03.sql
-- UniChat update 03: participant-private voice notes and student discovery.
-- Run after UniChat_Setup.sql and UniChat_Update_02.sql.
do $$begin if to_regclass('public.unichat_blocks') is null then raise exception 'Run UniChat_Update_02.sql before this update';end if;end$$;
create table if not exists public.unichat_voice_messages (
 id uuid primary key default gen_random_uuid(),sender uuid not null references public.unichat_profiles(id),
 recipient uuid not null references public.unichat_profiles(id),storage_path text not null unique,
 duration_seconds numeric not null check(duration_seconds>0 and duration_seconds<=60),
 mime_type text not null check(mime_type in ('audio/webm','audio/ogg','audio/mp4')),
 created_at timestamptz not null default now(),check(sender<>recipient)
);
create index if not exists unichat_voice_conversation_date on public.unichat_voice_messages(sender,recipient,created_at desc);
alter table public.unichat_voice_messages enable row level security;
create or replace function public.unichat_validate_voice() returns trigger language plpgsql security definer set search_path='' as $$
 begin
 if new.sender<>auth.uid() or not public.unichat_can_contact(new.recipient) or not public.unichat_feature('messaging') or not public.unichat_feature('uploads') then raise exception 'Voice notes require an accepted message request and an available recipient';end if;
 if new.storage_path !~ ('^'||new.sender::text||'/'||new.recipient::text||'/'||new.id::text||'\.(webm|ogg|m4a)$') then raise exception 'Invalid recording path';end if;
 if not exists(select 1 from storage.objects where bucket_id='unichat-voice' and name=new.storage_path) then raise exception 'Upload the recording before sending';end if;
 new.created_at:=now();return new;end $$;
drop trigger if exists unichat_validate_voice on public.unichat_voice_messages;
create trigger unichat_validate_voice before insert on public.unichat_voice_messages for each row execute function public.unichat_validate_voice();
revoke all on function public.unichat_validate_voice() from public,anon,authenticated;
drop policy if exists uc_voice_read on public.unichat_voice_messages;
create policy uc_voice_read on public.unichat_voice_messages for select to authenticated using(public.unichat_active() and (sender=auth.uid() or recipient=auth.uid()));
drop policy if exists uc_voice_send on public.unichat_voice_messages;
create policy uc_voice_send on public.unichat_voice_messages for insert to authenticated with check(public.unichat_active() and sender=auth.uid() and public.unichat_feature('messaging') and public.unichat_feature('uploads') and public.unichat_can_contact(recipient));
grant select,insert on public.unichat_voice_messages to authenticated;
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values('unichat-voice','unichat-voice',false,1048576,array['audio/webm','audio/ogg','audio/mp4']) on conflict(id) do update set public=false,file_size_limit=1048576,allowed_mime_types=array['audio/webm','audio/ogg','audio/mp4'];
create or replace function public.unichat_voice_upload_allowed(object_name text) returns boolean language plpgsql stable security definer set search_path='' as $$
 declare parts text[];
 begin
 parts:=string_to_array(object_name,'/');
 if array_length(parts,1)<>3 or parts[1]<>auth.uid()::text or parts[2] !~ '^[0-9a-f-]{36}$' or parts[3] !~ '^[0-9a-f-]{36}\.(webm|ogg|m4a)$' then return false;end if;
 return public.unichat_active() and public.unichat_feature('uploads') and public.unichat_feature('messaging') and public.unichat_can_contact(parts[2]::uuid);
 exception when invalid_text_representation then return false;
 end $$;
revoke all on function public.unichat_voice_upload_allowed(text) from public,anon;
grant execute on function public.unichat_voice_upload_allowed(text) to authenticated;
drop policy if exists uc_voice_file_upload on storage.objects;
create policy uc_voice_file_upload on storage.objects for insert to authenticated with check(bucket_id='unichat-voice' and public.unichat_voice_upload_allowed(name));
drop policy if exists uc_voice_file_read on storage.objects;
create policy uc_voice_file_read on storage.objects for select to authenticated using(bucket_id='unichat-voice' and public.unichat_active() and ((storage.foldername(name))[1]=auth.uid()::text or exists(select 1 from public.unichat_voice_messages v where v.storage_path=name and (v.sender=auth.uid() or v.recipient=auth.uid()))));
drop policy if exists uc_voice_orphan_remove on storage.objects;
create policy uc_voice_orphan_remove on storage.objects for delete to authenticated using(bucket_id='unichat-voice' and public.unichat_active() and (storage.foldername(name))[1]=auth.uid()::text and not exists(select 1 from public.unichat_voice_messages v where v.storage_path=name));

create or replace function public.unichat_discover_students(search_text text default '',school_filter text default '',department_filter text default '',level_filter text default '',result_offset integer default 0)
returns table(id uuid,username text,data jsonb,status text) language sql stable security invoker set search_path='' as $$
 select p.id,p.username,p.data,p.status from public.unichat_profiles p
 where public.unichat_active() and p.status='active' and p.id<>auth.uid()
 and (coalesce(trim(school_filter),'')='' or lower(trim(p.data->>'school'))=lower(trim(school_filter)))
 and (coalesce(trim(department_filter),'')='' or lower(trim(p.data->>'department'))=lower(trim(department_filter)))
 and (coalesce(trim(level_filter),'')='' or lower(trim(p.data->>'level'))=lower(trim(level_filter)))
 and (coalesce(trim(search_text),'')='' or concat_ws(' ',p.username,p.data->>'name',p.data->>'school',p.data->>'department') ilike '%'||left(trim(search_text),100)||'%')
 and not exists(select 1 from public.unichat_blocks b where b.blocker=auth.uid() and b.blocked=p.id)
 order by lower(p.data->>'name'),p.id limit 25 offset greatest(0,least(result_offset,100000))
$$;
create or replace function public.unichat_discovery_options() returns jsonb language sql stable security invoker set search_path='' as $$
 select jsonb_build_object(
 'schools',coalesce((select jsonb_agg(v order by v) from (select min(trim(data->>'school')) v from public.unichat_profiles where public.unichat_active() and status='active' and trim(coalesce(data->>'school',''))<>'' group by lower(trim(data->>'school')))s),'[]'::jsonb),
 'departments',coalesce((select jsonb_agg(v order by v) from (select min(trim(data->>'department')) v from public.unichat_profiles where public.unichat_active() and status='active' and trim(coalesce(data->>'department',''))<>'' group by lower(trim(data->>'department')))d),'[]'::jsonb),
 'levels',coalesce((select jsonb_agg(v order by v) from (select min(trim(data->>'level')) v from public.unichat_profiles where public.unichat_active() and status='active' and trim(coalesce(data->>'level',''))<>'' group by lower(trim(data->>'level')))l),'[]'::jsonb))
$$;
revoke all on function public.unichat_discover_students(text,text,text,text,integer),public.unichat_discovery_options() from public,anon;
grant execute on function public.unichat_discover_students(text,text,text,text,integer),public.unichat_discovery_options() to authenticated;
do $$begin
 if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='unichat_voice_messages') then alter publication supabase_realtime add table public.unichat_voice_messages;end if;
end$$;

-- UniChat_Update_04.sql
-- Priority upgrades. Apply after updates 02 and 03, or use UniChat_Combined_Upgrade.sql.
create table if not exists public.unichat_directory(id uuid primary key default gen_random_uuid(),school text not null unique check(length(trim(school)) between 2 and 150),departments text[] not null default '{}',active boolean not null default true);
create unique index if not exists uc_school_label on public.unichat_directory(lower(trim(school)));
create table if not exists public.unichat_follows(follower uuid not null references public.unichat_profiles(id),following uuid not null references public.unichat_profiles(id),created_at timestamptz not null default now(),primary key(follower,following),check(follower<>following));
create table if not exists public.unichat_chats(id uuid primary key default gen_random_uuid(),creator uuid not null references public.unichat_profiles(id),title text not null check(length(trim(title)) between 2 and 80),created_at timestamptz not null default now());
create table if not exists public.unichat_chat_members(chat_id uuid not null references public.unichat_chats(id),user_id uuid not null references public.unichat_profiles(id),status text not null default 'pending' check(status in ('pending','active')),created_at timestamptz not null default now(),primary key(chat_id,user_id));
create table if not exists public.unichat_chat_messages(id uuid primary key default gen_random_uuid(),chat_id uuid not null references public.unichat_chats(id),sender uuid not null references public.unichat_profiles(id),body text not null check(length(trim(body)) between 1 and 4000),created_at timestamptz not null default now());
create table if not exists public.unichat_attachments(id uuid primary key default gen_random_uuid(),sender uuid not null references public.unichat_profiles(id),recipient uuid references public.unichat_profiles(id),chat_id uuid references public.unichat_chats(id),storage_path text not null unique,filename text not null check(length(filename) between 1 and 150),mime_type text not null check(mime_type in ('image/jpeg','image/png','image/webp','image/gif','video/mp4','video/webm','application/pdf')),size_bytes integer not null check(size_bytes between 1 and 10485760),created_at timestamptz not null default now(),check((recipient is null)<>(chat_id is null)),check(sender<>recipient));
create table if not exists public.unichat_post_replies(id uuid primary key default gen_random_uuid(),comment_id text not null references public.unichat_content(id),author uuid not null references public.unichat_profiles(id),body text not null check(length(trim(body)) between 1 and 2000),created_at timestamptz not null default now());
create table if not exists public.unichat_notifications(id uuid primary key default gen_random_uuid(),recipient uuid not null references public.unichat_profiles(id),actor uuid references public.unichat_profiles(id),kind text not null,reference text not null,created_at timestamptz not null default now(),read_at timestamptz);
create index if not exists uc_notifications_recipient on public.unichat_notifications(recipient,created_at desc);
create table if not exists public.unichat_listings(id uuid primary key default gen_random_uuid(),author uuid not null references public.unichat_profiles(id),kind text not null check(kind in ('opportunity','marketplace')),title text not null check(length(trim(title)) between 2 and 120),body text not null check(length(trim(body)) between 2 and 3000),school text not null default 'Across schools',department text not null default '',price numeric check(price>=0 and price<=1000000000),external_url text check(external_url is null or external_url ~ '^https?://[^[:space:]]+$'),deadline timestamptz,status text not null default 'open' check(status in ('open','closed')),photo_path text,created_at timestamptz not null default now());

create or replace function public.unichat_group_member(group_id uuid) returns boolean language sql stable security definer set search_path='' as $$select exists(select 1 from public.unichat_chat_members where chat_id=group_id and user_id=auth.uid() and status='active')$$;
create or replace function public.unichat_group_invited(group_id uuid) returns boolean language sql stable security definer set search_path='' as $$select exists(select 1 from public.unichat_chat_members where chat_id=group_id and user_id=auth.uid())$$;
create or replace function public.unichat_group_create(chat_title text,invitees uuid[]) returns uuid language plpgsql security definer set search_path='' as $$
declare new_id uuid;peer uuid;begin
 if not public.unichat_active() or not public.unichat_feature('messaging') then raise exception 'Messaging is unavailable';end if;
 if cardinality(invitees) not between 1 and 20 then raise exception 'Choose between 1 and 20 connections';end if;
 insert into public.unichat_chats(creator,title) values(auth.uid(),trim(chat_title)) returning id into new_id;
 insert into public.unichat_chat_members(chat_id,user_id,status) values(new_id,auth.uid(),'active');
 foreach peer in array invitees loop
  if not public.unichat_can_contact(peer) then raise exception 'Invite only accepted, available connections';end if;
  insert into public.unichat_chat_members(chat_id,user_id) values(new_id,peer) on conflict do nothing;
 end loop;return new_id;end$$;
create or replace function public.unichat_group_respond(group_id uuid,accept_invite boolean) returns void language plpgsql security definer set search_path='' as $$begin
 if not public.unichat_active() then raise exception 'Account unavailable';end if;
 if accept_invite then update public.unichat_chat_members set status='active' where chat_id=group_id and user_id=auth.uid();else delete from public.unichat_chat_members where chat_id=group_id and user_id=auth.uid();end if;
 end$$;
create or replace function public.unichat_notify(target uuid,event_kind text,event_reference text) returns void language plpgsql security definer set search_path='' as $$begin
 if target is null or target=auth.uid() or exists(select 1 from public.unichat_blocks where (blocker=target and blocked=auth.uid()) or (blocked=target and blocker=auth.uid())) then return;end if;
 insert into public.unichat_notifications(recipient,actor,kind,reference) select target,auth.uid(),event_kind,event_reference where exists(select 1 from public.unichat_profiles where id=target and status='active');end$$;
create or replace function public.unichat_notify_mentions(body text,reference_id text) returns void language plpgsql security definer set search_path='' as $$declare mention text[];target uuid;begin
 for mention in select regexp_matches(body,'@([A-Za-z0-9_]{3,30})','g') loop select id into target from public.unichat_profiles where username=lower(mention[1]);perform public.unichat_notify(target,'mention',reference_id);end loop;end$$;
create or replace function public.unichat_notice_trigger() returns trigger language plpgsql security definer set search_path='' as $$declare target uuid;ref text;begin
 if tg_table_name='unichat_follows' then perform public.unichat_notify(new.following,'follow',new.follower::text);
 elsif tg_table_name='unichat_chat_members' then if new.status='pending' then perform public.unichat_notify(new.user_id,'group_invite',new.chat_id::text);end if;
 elsif tg_table_name='unichat_chat_messages' then for target in select user_id from public.unichat_chat_members where chat_id=new.chat_id and status='active' loop perform public.unichat_notify(target,'group_message',new.chat_id::text);end loop;
 elsif tg_table_name='unichat_attachments' then if new.recipient is not null then perform public.unichat_notify(new.recipient,'attachment',new.sender::text);else for target in select user_id from public.unichat_chat_members where chat_id=new.chat_id and status='active' loop perform public.unichat_notify(target,'group_message',new.chat_id::text);end loop;end if;
 elsif tg_table_name='unichat_voice_messages' then perform public.unichat_notify(new.recipient,'voice',new.sender::text);
 elsif tg_table_name='unichat_post_replies' then select owner,data->>'postId' into target,ref from public.unichat_content where id=new.comment_id and kind='comment';perform public.unichat_notify(target,'reply',ref);perform public.unichat_notify_mentions(new.body,ref);
 elsif tg_table_name='unichat_content' then
  if new.kind='message' then perform public.unichat_notify((new.data->>'recipient')::uuid,'message',new.owner::text);
  elsif new.kind='comment' then select owner into target from public.unichat_content where id=new.data->>'postId';perform public.unichat_notify(target,'comment',new.data->>'postId');perform public.unichat_notify_mentions(new.data->>'text',new.data->>'postId');
  elsif new.kind='post' then perform public.unichat_notify_mentions(new.data->>'text',new.id);end if;
 end if;return new;end$$;
create or replace function public.unichat_mark_read(notice_ids uuid[]) returns void language plpgsql security definer set search_path='' as $$begin update public.unichat_notifications set read_at=now() where recipient=auth.uid() and id=any(notice_ids);end$$;
create or replace function public.unichat_guard_dm_reply() returns trigger language plpgsql security definer set search_path='' as $$begin
 if new.kind='message' and new.data->>'reply_id' is not null and not exists(select 1 from public.unichat_content c where c.id=new.data->>'reply_id' and c.kind='message' and ((c.owner=new.owner and c.data->>'recipient'=new.data->>'recipient') or (c.owner::text=new.data->>'recipient' and c.data->>'recipient'=new.owner::text))) then raise exception 'Reply must belong to this conversation';end if;return new;end$$;
drop trigger if exists uc_guard_dm_reply on public.unichat_content;
create trigger uc_guard_dm_reply before insert on public.unichat_content for each row execute function public.unichat_guard_dm_reply();
create or replace function public.unichat_guard_priority_record() returns trigger language plpgsql security definer set search_path='' as $$begin
 if tg_op='UPDATE' then
  if new.id<>old.id or new.author<>old.author or new.created_at<>old.created_at then raise exception 'Record identity cannot change';end if;
  if tg_table_name='unichat_listings' then if new.kind<>old.kind then raise exception 'Listing type cannot change';end if;end if;
  if tg_table_name='unichat_post_replies' then if new.comment_id<>old.comment_id then raise exception 'Parent comment cannot change';end if;end if;
 end if;
 if tg_table_name='unichat_post_replies' then if not exists(select 1 from public.unichat_content where id=new.comment_id and kind='comment') then raise exception 'Comment not found';end if;end if;
 return new;end$$;
drop trigger if exists uc_guard_listing on public.unichat_listings;create trigger uc_guard_listing before update on public.unichat_listings for each row execute function public.unichat_guard_priority_record();
drop trigger if exists uc_guard_reply on public.unichat_post_replies;create trigger uc_guard_reply before insert or update on public.unichat_post_replies for each row execute function public.unichat_guard_priority_record();

create or replace function public.unichat_attachment_upload_allowed(object_name text) returns boolean language plpgsql stable security definer set search_path='' as $$declare p text[];begin
 p:=string_to_array(object_name,'/');if array_length(p,1)<>3 or p[1]<>auth.uid()::text or p[3] !~ '^[0-9a-f-]{36}\.(jpg|png|webp|gif|mp4|webm|pdf)$' then return false;end if;
 if not public.unichat_active() or not public.unichat_feature('messaging') or not public.unichat_feature('uploads') then return false;end if;
 if p[2] ~ '^dm-[0-9a-f-]{36}$' then return public.unichat_can_contact(substring(p[2] from 4)::uuid);elsif p[2] ~ '^group-[0-9a-f-]{36}$' then return public.unichat_group_member(substring(p[2] from 7)::uuid);end if;return false;exception when invalid_text_representation then return false;end$$;
create or replace function public.unichat_validate_attachment() returns trigger language plpgsql security definer set search_path='' as $$declare target text;begin
 if new.sender<>auth.uid() then raise exception 'Sender mismatch';end if;
 target:=case when new.recipient is not null then 'dm-'||new.recipient::text else 'group-'||new.chat_id::text end;
 if not public.unichat_attachment_upload_allowed(new.storage_path) or new.storage_path !~ ('^'||new.sender::text||'/'||target||'/'||new.id::text||'\.(jpg|png|webp|gif|mp4|webm|pdf)$') then raise exception 'Attachment target is unavailable';end if;
 if not exists(select 1 from storage.objects where bucket_id='unichat-chat-files' and name=new.storage_path) then raise exception 'Upload the file first';end if;new.created_at:=now();return new;end$$;
drop trigger if exists uc_validate_attachment on public.unichat_attachments;create trigger uc_validate_attachment before insert on public.unichat_attachments for each row execute function public.unichat_validate_attachment();

-- Public-facing profile photos still require a signed-in student to read.
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values('unichat-avatars','unichat-avatars',false,524288,array['image/jpeg','image/png','image/webp']),('unichat-chat-files','unichat-chat-files',false,10485760,array['image/jpeg','image/png','image/webp','image/gif','video/mp4','video/webm','application/pdf']) on conflict(id) do nothing;
drop policy if exists uc_avatars_read on storage.objects;create policy uc_avatars_read on storage.objects for select to authenticated using(bucket_id='unichat-avatars' and public.unichat_active());
drop policy if exists uc_avatars_upload on storage.objects;create policy uc_avatars_upload on storage.objects for insert to authenticated with check(bucket_id='unichat-avatars' and public.unichat_active() and public.unichat_feature('uploads') and (storage.foldername(name))[1]=auth.uid()::text);
drop policy if exists uc_avatars_remove on storage.objects;create policy uc_avatars_remove on storage.objects for delete to authenticated using(bucket_id='unichat-avatars' and public.unichat_active() and (storage.foldername(name))[1]=auth.uid()::text);
drop policy if exists uc_files_upload on storage.objects;create policy uc_files_upload on storage.objects for insert to authenticated with check(bucket_id='unichat-chat-files' and public.unichat_attachment_upload_allowed(name));
drop policy if exists uc_files_read on storage.objects;create policy uc_files_read on storage.objects for select to authenticated using(bucket_id='unichat-chat-files' and public.unichat_active() and ((storage.foldername(name))[1]=auth.uid()::text or exists(select 1 from public.unichat_attachments a where a.storage_path=name and (a.recipient=auth.uid() or (a.chat_id is not null and public.unichat_group_member(a.chat_id))))));
drop policy if exists uc_files_orphan_remove on storage.objects;create policy uc_files_orphan_remove on storage.objects for delete to authenticated using(bucket_id='unichat-chat-files' and public.unichat_active() and (storage.foldername(name))[1]=auth.uid()::text and not exists(select 1 from public.unichat_attachments where storage_path=name));

alter table public.unichat_directory enable row level security;alter table public.unichat_follows enable row level security;alter table public.unichat_chats enable row level security;alter table public.unichat_chat_members enable row level security;alter table public.unichat_chat_messages enable row level security;alter table public.unichat_attachments enable row level security;alter table public.unichat_post_replies enable row level security;alter table public.unichat_notifications enable row level security;alter table public.unichat_listings enable row level security;
drop policy if exists uc_directory_read on public.unichat_directory;create policy uc_directory_read on public.unichat_directory for select to anon,authenticated using(active or public.unichat_is_owner());
drop policy if exists uc_directory_owner on public.unichat_directory;create policy uc_directory_owner on public.unichat_directory for all to authenticated using(public.unichat_is_owner()) with check(public.unichat_is_owner());
drop policy if exists uc_follows_read on public.unichat_follows;create policy uc_follows_read on public.unichat_follows for select to authenticated using(public.unichat_active());
drop policy if exists uc_follows_add on public.unichat_follows;create policy uc_follows_add on public.unichat_follows for insert to authenticated with check(follower=auth.uid() and public.unichat_peer_available(following));
drop policy if exists uc_follows_remove on public.unichat_follows;create policy uc_follows_remove on public.unichat_follows for delete to authenticated using(follower=auth.uid());
drop policy if exists uc_chats_read on public.unichat_chats;create policy uc_chats_read on public.unichat_chats for select to authenticated using(public.unichat_active() and public.unichat_group_invited(id));
drop policy if exists uc_chat_members_read on public.unichat_chat_members;create policy uc_chat_members_read on public.unichat_chat_members for select to authenticated using(public.unichat_active() and (user_id=auth.uid() or public.unichat_group_member(chat_id)));
drop policy if exists uc_chat_messages_read on public.unichat_chat_messages;create policy uc_chat_messages_read on public.unichat_chat_messages for select to authenticated using(public.unichat_active() and public.unichat_group_member(chat_id));
drop policy if exists uc_chat_messages_add on public.unichat_chat_messages;create policy uc_chat_messages_add on public.unichat_chat_messages for insert to authenticated with check(public.unichat_active() and public.unichat_feature('messaging') and sender=auth.uid() and public.unichat_group_member(chat_id));
drop policy if exists uc_attachments_read on public.unichat_attachments;create policy uc_attachments_read on public.unichat_attachments for select to authenticated using(public.unichat_active() and (sender=auth.uid() or recipient=auth.uid() or (chat_id is not null and public.unichat_group_member(chat_id))));
drop policy if exists uc_attachments_add on public.unichat_attachments;create policy uc_attachments_add on public.unichat_attachments for insert to authenticated with check(public.unichat_active() and sender=auth.uid() and public.unichat_feature('uploads') and public.unichat_feature('messaging') and ((recipient is not null and public.unichat_can_contact(recipient)) or (chat_id is not null and public.unichat_group_member(chat_id))));
drop policy if exists uc_post_replies_read on public.unichat_post_replies;create policy uc_post_replies_read on public.unichat_post_replies for select to authenticated using(public.unichat_active());
drop policy if exists uc_post_replies_add on public.unichat_post_replies;create policy uc_post_replies_add on public.unichat_post_replies for insert to authenticated with check(public.unichat_active() and author=auth.uid());
drop policy if exists uc_post_replies_edit on public.unichat_post_replies;create policy uc_post_replies_edit on public.unichat_post_replies for update to authenticated using(public.unichat_active() and (author=auth.uid() or public.unichat_is_owner())) with check(public.unichat_active() and (author=auth.uid() or public.unichat_is_owner()));
drop policy if exists uc_notice_read on public.unichat_notifications;create policy uc_notice_read on public.unichat_notifications for select to authenticated using(public.unichat_active() and recipient=auth.uid());
drop policy if exists uc_listings_read on public.unichat_listings;create policy uc_listings_read on public.unichat_listings for select to authenticated using(public.unichat_active());
drop policy if exists uc_listings_add on public.unichat_listings;create policy uc_listings_add on public.unichat_listings for insert to authenticated with check(public.unichat_active() and author=auth.uid());
drop policy if exists uc_listings_edit on public.unichat_listings;create policy uc_listings_edit on public.unichat_listings for update to authenticated using(public.unichat_active() and (author=auth.uid() or public.unichat_is_owner())) with check(public.unichat_active() and (author=auth.uid() or public.unichat_is_owner()));
grant select on public.unichat_directory to anon;grant select,insert,update,delete on public.unichat_directory to authenticated;grant select,insert,delete on public.unichat_follows to authenticated;grant select on public.unichat_chats,public.unichat_chat_members,public.unichat_notifications to authenticated;grant select,insert on public.unichat_chat_messages,public.unichat_attachments to authenticated;grant select,insert,update on public.unichat_post_replies,public.unichat_listings to authenticated;

do $$declare t text;begin foreach t in array array['unichat_follows','unichat_chat_members','unichat_chat_messages','unichat_attachments','unichat_voice_messages','unichat_post_replies','unichat_content'] loop execute format('drop trigger if exists uc_priority_notice on public.%I',t);execute format('create trigger uc_priority_notice after insert on public.%I for each row execute function public.unichat_notice_trigger()',t);end loop;end$$;
revoke all on function public.unichat_notify(uuid,text,text),public.unichat_notify_mentions(text,text),public.unichat_notice_trigger(),public.unichat_guard_dm_reply(),public.unichat_guard_priority_record(),public.unichat_validate_attachment() from public,anon,authenticated;
revoke all on function public.unichat_group_member(uuid),public.unichat_group_invited(uuid),public.unichat_group_create(text,uuid[]),public.unichat_group_respond(uuid,boolean),public.unichat_mark_read(uuid[]),public.unichat_attachment_upload_allowed(text) from public,anon;
grant execute on function public.unichat_group_member(uuid),public.unichat_group_invited(uuid),public.unichat_group_create(text,uuid[]),public.unichat_group_respond(uuid,boolean),public.unichat_mark_read(uuid[]),public.unichat_attachment_upload_allowed(text) to authenticated;
do $$declare t text;begin foreach t in array array['unichat_follows','unichat_chats','unichat_chat_members','unichat_chat_messages','unichat_attachments','unichat_post_replies','unichat_notifications','unichat_listings','unichat_directory'] loop if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename=t) then execute format('alter publication supabase_realtime add table public.%I',t);end if;end loop;end$$;

-- UniChat_Update_05.sql
-- Reels, 24-hour Stories and profile covers. Included in the combined upgrade.
create table if not exists public.unichat_media (
 id uuid primary key default gen_random_uuid(),
 author uuid not null references public.unichat_profiles(id),
 kind text not null check(kind in ('reel','story')),
 storage_path text not null unique,
 mime_type text not null check(mime_type in ('image/jpeg','image/png','image/webp','video/mp4','video/webm')),
 size_bytes integer not null check(size_bytes between 1 and 20971520),
 duration_seconds numeric not null default 0 check(duration_seconds>=0 and duration_seconds<=60),
 caption text not null default '' check(length(caption)<=1500),
 created_at timestamptz not null default now(),
 expires_at timestamptz,
 check((kind='reel' and mime_type like 'video/%' and duration_seconds>0 and expires_at is null) or
       (kind='story' and expires_at is not null and ((mime_type like 'image/%' and size_bytes<=5242880 and duration_seconds=0) or (mime_type like 'video/%' and duration_seconds>0))))
);
create index if not exists uc_media_feed on public.unichat_media(kind,created_at desc);
create index if not exists uc_story_expiry on public.unichat_media(expires_at) where kind='story';
create table if not exists public.unichat_reel_likes(
 reel_id uuid not null references public.unichat_media(id) on delete cascade,
 user_id uuid not null references public.unichat_profiles(id),
 created_at timestamptz not null default now(),primary key(reel_id,user_id)
);
create table if not exists public.unichat_reel_comments(
 id uuid primary key default gen_random_uuid(),reel_id uuid not null references public.unichat_media(id) on delete cascade,
 author uuid not null references public.unichat_profiles(id),body text not null check(length(trim(body)) between 1 and 2000),
 created_at timestamptz not null default now()
);
create index if not exists uc_reel_comments on public.unichat_reel_comments(reel_id,created_at);

create or replace function public.unichat_media_visible(media_id uuid) returns boolean language sql stable security definer set search_path='' as $$
 select public.unichat_active() and exists(select 1 from public.unichat_media m join public.unichat_profiles p on p.id=m.author
 where m.id=media_id and p.status='active' and (m.kind='reel' or m.expires_at>now()) and
 not exists(select 1 from public.unichat_blocks b where (b.blocker=auth.uid() and b.blocked=m.author) or (b.blocked=auth.uid() and b.blocker=m.author)))
$$;
create or replace function public.unichat_media_upload_allowed(object_name text) returns boolean language plpgsql stable security definer set search_path='' as $$
declare p text[];begin
 p:=string_to_array(object_name,'/');
 return public.unichat_active() and public.unichat_feature('uploads') and public.unichat_feature('posting') and array_length(p,1)=3 and p[1]=auth.uid()::text and p[2] in ('reel','story') and public.unichat_feature(case p[2] when 'reel' then 'reels' else 'stories' end) and p[3] ~ '^[0-9a-f-]{36}\.(jpg|png|webp|mp4|webm)$' and (p[2]<>'reel' or p[3] ~ '\.(mp4|webm)$');
end$$;
create or replace function public.unichat_validate_media() returns trigger language plpgsql security definer set search_path='' as $$
declare ext text;object_meta jsonb;begin
 ext:=case new.mime_type when 'image/jpeg' then 'jpg' when 'image/png' then 'png' when 'image/webp' then 'webp' when 'video/mp4' then 'mp4' when 'video/webm' then 'webm' else '' end;
 if tg_op='UPDATE' then
  if new.id<>old.id or new.author<>old.author or new.kind<>old.kind or new.storage_path<>old.storage_path or new.mime_type<>old.mime_type or new.size_bytes<>old.size_bytes or new.duration_seconds<>old.duration_seconds or new.created_at<>old.created_at or new.expires_at is distinct from old.expires_at then raise exception 'Only the caption can change';end if;
 else
  if new.author<>auth.uid() or not public.unichat_media_upload_allowed(new.storage_path) or new.storage_path<>new.author::text||'/'||new.kind||'/'||new.id::text||'.'||ext then raise exception 'Invalid media upload';end if;
  select to_jsonb(o)->'metadata' into object_meta from storage.objects o where bucket_id='unichat-social-media' and name=new.storage_path;
  if not found then raise exception 'Upload the media first';end if;
  if object_meta is not null and ((object_meta->>'size')::bigint is distinct from new.size_bytes::bigint or object_meta->>'mimetype' is distinct from new.mime_type) then raise exception 'Media size or type does not match the stored upload';end if;
  new.created_at:=now();new.expires_at:=case when new.kind='story' then now()+interval '24 hours' else null end;
 end if;return new;
end$$;
drop trigger if exists uc_validate_media on public.unichat_media;
create trigger uc_validate_media before insert or update on public.unichat_media for each row execute function public.unichat_validate_media();
create or replace function public.unichat_validate_reel_interaction() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if not public.unichat_media_visible(new.reel_id) or not exists(select 1 from public.unichat_media where id=new.reel_id and kind='reel') then raise exception 'Reel is unavailable';end if;
 new.created_at:=now();return new;
end$$;
drop trigger if exists uc_validate_reel_like on public.unichat_reel_likes;
create trigger uc_validate_reel_like before insert on public.unichat_reel_likes for each row execute function public.unichat_validate_reel_interaction();
drop trigger if exists uc_validate_reel_comment on public.unichat_reel_comments;
create trigger uc_validate_reel_comment before insert on public.unichat_reel_comments for each row execute function public.unichat_validate_reel_interaction();

alter table public.unichat_media enable row level security;
alter table public.unichat_reel_likes enable row level security;
alter table public.unichat_reel_comments enable row level security;
drop policy if exists uc_media_read on public.unichat_media;
create policy uc_media_read on public.unichat_media for select to authenticated using(public.unichat_media_visible(id) or (public.unichat_active() and (author=auth.uid() or public.unichat_is_owner())));
drop policy if exists uc_media_add on public.unichat_media;
create policy uc_media_add on public.unichat_media for insert to authenticated with check(author=auth.uid() and public.unichat_active() and public.unichat_feature('uploads') and public.unichat_feature('posting'));
drop policy if exists uc_media_edit on public.unichat_media;
create policy uc_media_edit on public.unichat_media for update to authenticated using(public.unichat_active() and (author=auth.uid() or public.unichat_is_owner())) with check(public.unichat_active() and (author=auth.uid() or public.unichat_is_owner()));
drop policy if exists uc_media_remove on public.unichat_media;
create policy uc_media_remove on public.unichat_media for delete to authenticated using(public.unichat_active() and (author=auth.uid() or public.unichat_is_owner()));
drop policy if exists uc_reel_likes_read on public.unichat_reel_likes;
create policy uc_reel_likes_read on public.unichat_reel_likes for select to authenticated using(public.unichat_media_visible(reel_id));
drop policy if exists uc_reel_likes_add on public.unichat_reel_likes;
create policy uc_reel_likes_add on public.unichat_reel_likes for insert to authenticated with check(user_id=auth.uid() and public.unichat_active());
drop policy if exists uc_reel_likes_remove on public.unichat_reel_likes;
create policy uc_reel_likes_remove on public.unichat_reel_likes for delete to authenticated using(user_id=auth.uid());
drop policy if exists uc_reel_comments_read on public.unichat_reel_comments;
create policy uc_reel_comments_read on public.unichat_reel_comments for select to authenticated using(public.unichat_media_visible(reel_id));
drop policy if exists uc_reel_comments_add on public.unichat_reel_comments;
create policy uc_reel_comments_add on public.unichat_reel_comments for insert to authenticated with check(author=auth.uid() and public.unichat_active());
drop policy if exists uc_reel_comments_remove on public.unichat_reel_comments;
create policy uc_reel_comments_remove on public.unichat_reel_comments for delete to authenticated using(public.unichat_active() and (author=auth.uid() or public.unichat_is_owner()));
grant select,insert,update,delete on public.unichat_media to authenticated;
grant select,insert,delete on public.unichat_reel_likes,public.unichat_reel_comments to authenticated;

create or replace function public.unichat_reel_stats(reel_ids uuid[]) returns table(reel_id uuid,likes bigint,comments bigint,liked boolean) language sql stable security definer set search_path='' as $$
 select m.id,(select count(*) from public.unichat_reel_likes l where l.reel_id=m.id),
 (select count(*) from public.unichat_reel_comments c where c.reel_id=m.id),
 exists(select 1 from public.unichat_reel_likes l where l.reel_id=m.id and l.user_id=auth.uid())
 from public.unichat_media m where m.id=any(reel_ids[1:20]) and m.kind='reel' and public.unichat_media_visible(m.id)
$$;
revoke all on function public.unichat_reel_stats(uuid[]) from public,anon;
grant execute on function public.unichat_reel_stats(uuid[]) to authenticated;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values
 ('unichat-social-media','unichat-social-media',false,20971520,array['image/jpeg','image/png','image/webp','video/mp4','video/webm']),
 ('unichat-covers','unichat-covers',false,1048576,array['image/jpeg']) on conflict(id) do nothing;
drop policy if exists uc_media_files_add on storage.objects;
create policy uc_media_files_add on storage.objects for insert to authenticated with check(bucket_id='unichat-social-media' and public.unichat_media_upload_allowed(name));
drop policy if exists uc_media_files_read on storage.objects;
create policy uc_media_files_read on storage.objects for select to authenticated using(bucket_id='unichat-social-media' and public.unichat_active() and ((storage.foldername(name))[1]=auth.uid()::text or public.unichat_is_owner() or exists(select 1 from public.unichat_media m where m.storage_path=name and public.unichat_media_visible(m.id))));
drop policy if exists uc_media_files_remove on storage.objects;
create policy uc_media_files_remove on storage.objects for delete to authenticated using(bucket_id='unichat-social-media' and public.unichat_active() and ((storage.foldername(name))[1]=auth.uid()::text or public.unichat_is_owner()));
drop policy if exists uc_cover_add on storage.objects;
create policy uc_cover_add on storage.objects for insert to authenticated with check(bucket_id='unichat-covers' and public.unichat_active() and public.unichat_feature('uploads') and name ~ ('^'||auth.uid()::text||'/[0-9a-f-]{36}\.jpg$'));
drop policy if exists uc_cover_read on storage.objects;
create policy uc_cover_read on storage.objects for select to authenticated using(bucket_id='unichat-covers' and public.unichat_active() and ((storage.foldername(name))[1]=auth.uid()::text or public.unichat_is_owner() or exists(select 1 from public.unichat_profiles p where p.data->>'cover_path'=name and p.status='active' and not exists(select 1 from public.unichat_blocks b where (b.blocker=auth.uid() and b.blocked=p.id) or (b.blocked=auth.uid() and b.blocker=p.id)))));
drop policy if exists uc_cover_remove on storage.objects;
create policy uc_cover_remove on storage.objects for delete to authenticated using(bucket_id='unichat-covers' and public.unichat_active() and ((storage.foldername(name))[1]=auth.uid()::text or public.unichat_is_owner()));
create or replace function public.unichat_validate_cover() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.data->>'cover_path' is not null and (tg_op='INSERT' or new.data->>'cover_path' is distinct from old.data->>'cover_path') then
  if new.data->>'cover_path' !~ ('^'||new.id::text||'/[0-9a-f-]{36}\.jpg$') or not exists(select 1 from storage.objects where bucket_id='unichat-covers' and name=new.data->>'cover_path') then raise exception 'Upload this student cover photo first';end if;
 end if;return new;
end$$;
drop trigger if exists uc_validate_cover on public.unichat_profiles;
create trigger uc_validate_cover before insert or update on public.unichat_profiles for each row execute function public.unichat_validate_cover();
revoke all on function public.unichat_media_visible(uuid),public.unichat_media_upload_allowed(text) from public,anon;
grant execute on function public.unichat_media_visible(uuid),public.unichat_media_upload_allowed(text) to authenticated;
revoke all on function public.unichat_validate_media(),public.unichat_validate_reel_interaction(),public.unichat_validate_cover() from public,anon,authenticated;
do $$declare t text;begin foreach t in array array['unichat_media','unichat_reel_likes','unichat_reel_comments'] loop if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename=t) then execute format('alter publication supabase_realtime add table public.%I',t);end if;end loop;end$$;

-- UniChat_Update_06.sql
-- Owner operations. Run through the combined upgrade. No private-chat browsing access.
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

-- UniChat_Update_07.sql
-- Searchable follower/following lists with viewer-specific visibility and pagination.
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

-- UniChat_Update_08.sql
-- Private birthdays, user preferences, profile/post audiences and follow approval.
create table if not exists public.unichat_user_settings(
 user_id uuid primary key references public.unichat_profiles(id),birth_date date,
 birthday_visibility text not null default 'private' check(birthday_visibility in ('private','day_month','full')),
 profile_visibility text not null default 'students' check(profile_visibility in ('students','followers','self')),
 default_audience text not null default 'students' check(default_audience in ('students','followers','self')),
 message_policy text not null default 'requests' check(message_policy in ('requests','followers','mutual','nobody')),
 follow_policy text not null default 'everyone' check(follow_policy in ('everyone','approval')),
 read_receipts boolean not null default false,share_online boolean not null default false,
 birthday_reminders boolean not null default true,opportunity_reminders boolean not null default true,
 preferred_school text not null default '',preferred_department text not null default '',
 notification_preferences jsonb not null default '{}'::jsonb,
 check(birth_date is null or birth_date between date '1900-01-01' and current_date),
 check(length(preferred_school)<=150 and length(preferred_department)<=150)
);
create table if not exists public.unichat_follow_requests(
 follower uuid not null references public.unichat_profiles(id),following uuid not null references public.unichat_profiles(id),
 status text not null default 'pending' check(status in ('pending','accepted','declined')),
 created_at timestamptz not null default now(),primary key(follower,following),check(follower<>following)
);
create table if not exists public.unichat_reminder_events(user_id uuid not null references public.unichat_profiles(id),kind text not null,reference text not null,period text not null,primary key(user_id,kind,reference,period));
create or replace function public.unichat_profile_visible(student_id uuid) returns boolean language sql stable security definer set search_path='' as $$
 select public.unichat_active() and exists(select 1 from public.unichat_profiles p where p.id=student_id and p.status='active')
 and (student_id=auth.uid() or (not exists(select 1 from public.unichat_blocks b where (b.blocker=auth.uid() and b.blocked=student_id) or (b.blocked=auth.uid() and b.blocker=student_id)) and
 (coalesce((select profile_visibility from public.unichat_user_settings where user_id=student_id),'students')='students' or (coalesce((select profile_visibility from public.unichat_user_settings where user_id=student_id),'students')='followers' and exists(select 1 from public.unichat_follows where follower=auth.uid() and following=student_id)))))
$$;
create or replace function public.unichat_social_visible(student_id uuid) returns boolean language sql stable security definer set search_path='' as $$select public.unichat_profile_visible(student_id)$$;
create or replace function public.unichat_post_visible(post_id text) returns boolean language sql stable security definer set search_path='' as $$
 select public.unichat_active() and exists(select 1 from public.unichat_content c where c.id=post_id and c.kind='post' and
 (c.owner=auth.uid() or (public.unichat_profile_visible(c.owner) and (coalesce(c.data->>'audience','students')='students' or (c.data->>'audience'='followers' and exists(select 1 from public.unichat_follows where follower=auth.uid() and following=c.owner))))))
$$;
create or replace function public.unichat_my_settings() returns jsonb language plpgsql security definer set search_path='' as $$
declare value jsonb;candidate text;birthday date;begin
 if auth.uid() is null or not exists(select 1 from auth.users where id=auth.uid()) then raise exception 'Sign in to continue';end if;
 if not exists(select 1 from public.unichat_profiles where id=auth.uid()) then return '{}'::jsonb;end if;
 if not exists(select 1 from public.unichat_user_settings where user_id=auth.uid()) then
  select to_jsonb(u)->'raw_user_meta_data'->>'birth_date' into candidate from auth.users u where id=auth.uid();
  begin birthday:=candidate::date;exception when others then birthday:=null;end;
  if birthday<date '1900-01-01' or birthday>current_date then birthday:=null;end if;
  insert into public.unichat_user_settings(user_id,birth_date) values(auth.uid(),birthday) on conflict do nothing;
 end if;
 select to_jsonb(s) into value from public.unichat_user_settings s where user_id=auth.uid();return value;
end$$;
create or replace function public.unichat_save_my_settings(payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$begin
 if not public.unichat_active() then raise exception 'An active account is required';end if;
 perform public.unichat_my_settings();
 update public.unichat_user_settings set
 birth_date=case when payload?'birth_date' then nullif(payload->>'birth_date','')::date else birth_date end,
 birthday_visibility=coalesce(payload->>'birthday_visibility',birthday_visibility),profile_visibility=coalesce(payload->>'profile_visibility',profile_visibility),
 default_audience=coalesce(payload->>'default_audience',default_audience),message_policy=coalesce(payload->>'message_policy',message_policy),follow_policy=coalesce(payload->>'follow_policy',follow_policy),
 read_receipts=coalesce((payload->>'read_receipts')::boolean,read_receipts),share_online=coalesce((payload->>'share_online')::boolean,share_online),
 birthday_reminders=coalesce((payload->>'birthday_reminders')::boolean,birthday_reminders),opportunity_reminders=coalesce((payload->>'opportunity_reminders')::boolean,opportunity_reminders),
 preferred_school=coalesce(payload->>'preferred_school',preferred_school),preferred_department=coalesce(payload->>'preferred_department',preferred_department),
 notification_preferences=coalesce(payload->'notification_preferences',notification_preferences) where user_id=auth.uid();
 if (select birthday_visibility='private' from public.unichat_user_settings where user_id=auth.uid()) then delete from public.unichat_notifications where actor=auth.uid() and kind='birthday';end if;
 return public.unichat_my_settings();
end$$;
-- Never copy a private date into the public JSON profile.
create or replace function public.unichat_strip_private_profile() returns trigger language plpgsql set search_path='' as $$begin
 new.data:=new.data-'birth_date'-'dob'-'date_of_birth'-'birthday';return new;
end$$;
drop trigger if exists uc_private_profile_fields on public.unichat_profiles;create trigger uc_private_profile_fields before insert or update on public.unichat_profiles for each row execute function public.unichat_strip_private_profile();
update public.unichat_profiles set data=data-'birth_date'-'dob'-'date_of_birth'-'birthday' where data?'birth_date' or data?'dob' or data?'date_of_birth' or data?'birthday';
drop policy if exists unichat_profile_read on public.unichat_profiles;create policy unichat_profile_read on public.unichat_profiles for select to authenticated using(id=auth.uid() or public.unichat_is_owner() or public.unichat_profile_visible(id));
drop policy if exists unichat_content_read on public.unichat_content;create policy unichat_content_read on public.unichat_content for select to authenticated using(public.unichat_active() and (
 (kind='post' and public.unichat_post_visible(id)) or (kind in ('like','comment') and public.unichat_post_visible(data->>'postId')) or (kind='state' and owner=auth.uid()) or (kind='report' and public.unichat_is_owner()) or (kind='message' and (owner=auth.uid() or data->>'recipient'=auth.uid()::text))));
create or replace function public.unichat_post_audience_guard() returns trigger language plpgsql security definer set search_path='' as $$begin
 if new.kind='post' then
  if not (new.data?'audience') then new.data:=new.data||jsonb_build_object('audience',coalesce((select default_audience from public.unichat_user_settings where user_id=new.owner),'students'));end if;
  if coalesce(new.data->>'audience','') not in ('students','followers','self') then raise exception 'Choose a valid post audience';end if;
 elsif new.kind in ('like','comment') then
  if not public.unichat_post_visible(new.data->>'postId') then raise exception 'This post is unavailable';end if;
 end if;return new;
end$$;
drop trigger if exists uc_post_audience_guard on public.unichat_content;create trigger uc_post_audience_guard before insert or update on public.unichat_content for each row execute function public.unichat_post_audience_guard();
drop policy if exists uc_post_replies_read on public.unichat_post_replies;create policy uc_post_replies_read on public.unichat_post_replies for select to authenticated using(exists(select 1 from public.unichat_content c where c.id=comment_id and public.unichat_post_visible(c.data->>'postId')));
create or replace function public.unichat_post_file_visible(object_name text) returns boolean language sql stable security definer set search_path='' as $$select public.unichat_active() and ((storage.foldername(object_name))[1]=auth.uid()::text or exists(select 1 from public.unichat_content c where c.kind='post' and c.data->>'media_path'=object_name and public.unichat_post_visible(c.id)))$$;
drop policy if exists unichat_media_read on storage.objects;create policy unichat_media_read on storage.objects for select to authenticated using(bucket_id='unichat-media' and public.unichat_post_file_visible(name));
drop policy if exists uc_avatars_read on storage.objects;create policy uc_avatars_read on storage.objects for select to authenticated using(bucket_id='unichat-avatars' and public.unichat_active() and ((storage.foldername(name))[1]=auth.uid()::text or exists(select 1 from public.unichat_profiles p where p.data->>'avatar_path'=name and public.unichat_profile_visible(p.id))));
drop policy if exists uc_cover_read on storage.objects;create policy uc_cover_read on storage.objects for select to authenticated using(bucket_id='unichat-covers' and public.unichat_active() and ((storage.foldername(name))[1]=auth.uid()::text or exists(select 1 from public.unichat_profiles p where p.data->>'cover_path'=name and public.unichat_profile_visible(p.id))));

create or replace function public.unichat_message_allowed(peer uuid) returns boolean language sql stable security definer set search_path='' as $$select public.unichat_peer_available(peer) and case coalesce((select message_policy from public.unichat_user_settings where user_id=peer),'requests') when 'nobody' then false when 'followers' then exists(select 1 from public.unichat_follows where follower=auth.uid() and following=peer) when 'mutual' then exists(select 1 from public.unichat_follows where follower=auth.uid() and following=peer) and exists(select 1 from public.unichat_follows where follower=peer and following=auth.uid()) else true end$$;
create or replace function public.unichat_can_contact(peer uuid) returns boolean language sql stable security definer set search_path='' as $$select public.unichat_message_allowed(peer) and exists(select 1 from public.unichat_contacts where status='accepted' and ((sender=auth.uid() and recipient=peer) or (recipient=auth.uid() and sender=peer)))$$;
create or replace function public.unichat_request_privacy_guard() returns trigger language plpgsql security definer set search_path='' as $$begin
 if tg_op='INSERT' then if not public.unichat_message_allowed(new.recipient) then raise exception 'This student is not accepting this message request';end if;end if;return new;
end$$;
drop trigger if exists uc_request_privacy_guard on public.unichat_contacts;create trigger uc_request_privacy_guard before insert on public.unichat_contacts for each row execute function public.unichat_request_privacy_guard();
create or replace function public.unichat_follow_approval_guard() returns trigger language plpgsql security definer set search_path='' as $$begin
 if coalesce((select follow_policy from public.unichat_user_settings where user_id=new.following),'everyone')='approval' and not exists(select 1 from public.unichat_follow_requests where follower=new.follower and following=new.following and status='accepted') then raise exception 'Send a follow request first';end if;return new;
end$$;
drop trigger if exists uc_follow_approval on public.unichat_follows;create trigger uc_follow_approval before insert on public.unichat_follows for each row execute function public.unichat_follow_approval_guard();
create or replace function public.unichat_follow_change(peer uuid) returns text language plpgsql security definer set search_path='' as $$begin
 if not public.unichat_peer_available(peer) or not public.unichat_feature('following') then raise exception 'Following is unavailable';end if;
 if exists(select 1 from public.unichat_follows where follower=auth.uid() and following=peer) then delete from public.unichat_follows where follower=auth.uid() and following=peer;delete from public.unichat_follow_requests where follower=auth.uid() and following=peer;return 'none';end if;
 if exists(select 1 from public.unichat_follow_requests where follower=auth.uid() and following=peer and status='pending') then delete from public.unichat_follow_requests where follower=auth.uid() and following=peer;return 'none';end if;
 if coalesce((select follow_policy from public.unichat_user_settings where user_id=peer),'everyone')='approval' then
  insert into public.unichat_follow_requests(follower,following) values(auth.uid(),peer) on conflict(follower,following) do update set status='pending',created_at=now();
  perform public.unichat_notify(peer,'follow_request',auth.uid()::text);return 'pending';
 end if;
 insert into public.unichat_follows(follower,following) values(auth.uid(),peer) on conflict do nothing;return 'following';
end$$;
create or replace function public.unichat_follow_respond(peer uuid,accept_request boolean) returns void language plpgsql security definer set search_path='' as $$begin
 if not public.unichat_peer_available(peer) then raise exception 'This student is unavailable';end if;
 if not exists(select 1 from public.unichat_follow_requests where follower=peer and following=auth.uid() and status='pending') then raise exception 'Request unavailable';end if;
 update public.unichat_follow_requests set status=case when accept_request then 'accepted' else 'declined' end where follower=peer and following=auth.uid();
 if accept_request then insert into public.unichat_follows(follower,following) values(peer,auth.uid()) on conflict do nothing;perform public.unichat_notify(peer,'follow_accepted',auth.uid()::text);end if;
end$$;
create or replace function public.unichat_relation_states(student_ids uuid[]) returns jsonb language sql stable security definer set search_path='' as $$select coalesce(jsonb_object_agg(p.id::text,case when exists(select 1 from public.unichat_follows where follower=auth.uid() and following=p.id) then 'following' when exists(select 1 from public.unichat_follow_requests where follower=auth.uid() and following=p.id and status='pending') then 'pending' else 'none' end),'{}'::jsonb) from public.unichat_profiles p where p.id=any(student_ids[1:100]) and public.unichat_active()$$;

create or replace function public.unichat_public_birthday(student_id uuid) returns jsonb language sql stable security definer set search_path='' as $$select case when public.unichat_profile_visible(student_id) and birthday_visibility<>'private' and birth_date is not null then jsonb_build_object('day',extract(day from birth_date),'month',extract(month from birth_date),'year',case when birthday_visibility='full' then extract(year from birth_date) else null end) else null end from public.unichat_user_settings where user_id=student_id$$;
create or replace function public.unichat_birthdays(days_ahead integer default 7) returns jsonb language plpgsql security definer set search_path='' as $$
declare today date;candidate date;r record;result jsonb:='[]';inserted integer;begin
 if not public.unichat_active() then raise exception 'Sign in to continue';end if;
 perform public.unichat_my_settings();today:=(now() at time zone 'Africa/Lagos')::date;
 for r in select p.id,p.data,s.birth_date from public.unichat_profiles p join public.unichat_user_settings s on s.user_id=p.id where p.id<>auth.uid() and public.unichat_profile_visible(p.id) and s.birthday_visibility<>'private' and s.birth_date is not null and exists(select 1 from public.unichat_follows where follower=auth.uid() and following=p.id) and exists(select 1 from public.unichat_follows where follower=p.id and following=auth.uid()) loop
  -- A 29 February birthday is observed on 28 February in a non-leap year.
  candidate:=make_date(extract(year from today)::int,extract(month from r.birth_date)::int,least(extract(day from r.birth_date)::int,extract(day from(date_trunc('month',make_date(extract(year from today)::int,extract(month from r.birth_date)::int,1))+interval '1 month - 1 day'))::int));
  if candidate<today then candidate:=make_date(extract(year from today)::int+1,extract(month from r.birth_date)::int,least(extract(day from r.birth_date)::int,extract(day from(date_trunc('month',make_date(extract(year from today)::int+1,extract(month from r.birth_date)::int,1))+interval '1 month - 1 day'))::int));end if;
  if candidate<=today+greatest(0,least(days_ahead,30)) then result:=result||jsonb_build_array(jsonb_build_object('id',r.id,'name',r.data->>'name','day',extract(day from r.birth_date),'month',extract(month from r.birth_date),'days_until',candidate-today));end if;
  if candidate=today and (select birthday_reminders from public.unichat_user_settings where user_id=auth.uid()) then
   insert into public.unichat_reminder_events(user_id,kind,reference,period) values(auth.uid(),'birthday',r.id::text,extract(year from today)::text) on conflict do nothing;get diagnostics inserted=row_count;
   if inserted=1 then insert into public.unichat_notifications(recipient,actor,kind,reference) values(auth.uid(),r.id,'birthday',r.id::text);end if;
  end if;
 end loop;return result;
end$$;

alter table public.unichat_user_settings enable row level security;alter table public.unichat_follow_requests enable row level security;alter table public.unichat_reminder_events enable row level security;
drop policy if exists uc_my_settings_read on public.unichat_user_settings;create policy uc_my_settings_read on public.unichat_user_settings for select to authenticated using(user_id=auth.uid());
drop policy if exists uc_follow_requests_read on public.unichat_follow_requests;create policy uc_follow_requests_read on public.unichat_follow_requests for select to authenticated using(public.unichat_active() and (follower=auth.uid() or following=auth.uid()));
grant select on public.unichat_user_settings,public.unichat_follow_requests to authenticated;
revoke all on function public.unichat_strip_private_profile(),public.unichat_post_audience_guard(),public.unichat_request_privacy_guard(),public.unichat_follow_approval_guard() from public,anon,authenticated;
do $$declare signature text;begin foreach signature in array array['unichat_profile_visible(uuid)','unichat_post_visible(text)','unichat_my_settings()','unichat_save_my_settings(jsonb)','unichat_post_file_visible(text)','unichat_message_allowed(uuid)','unichat_follow_change(uuid)','unichat_follow_respond(uuid,boolean)','unichat_relation_states(uuid[])','unichat_public_birthday(uuid)','unichat_birthdays(integer)'] loop execute 'revoke all on function public.'||signature||' from public,anon';execute 'grant execute on function public.'||signature||' to authenticated';end loop;end$$;

-- UniChat_Update_09.sql
-- Student matching, collaboration profiles, academic hubs and opportunity preferences.
create table if not exists public.unichat_collaboration(
 user_id uuid primary key references public.unichat_profiles(id),interests text[] not null default '{}',skills text[] not null default '{}',courses text[] not null default '{}',goals text[] not null default '{}',
 study_days text[] not null default '{}',study_periods text[] not null default '{}',study_mode text not null default 'either' check(study_mode in ('online','campus','either')),
 open_to_study boolean not null default false,discoverable boolean not null default true,about text not null default '' check(length(about)<=1000),
 check(cardinality(interests)<=20 and cardinality(skills)<=20 and cardinality(courses)<=20 and cardinality(goals)<=10 and cardinality(study_days)<=7 and cardinality(study_periods)<=4)
);
create table if not exists public.unichat_projects(id uuid primary key default gen_random_uuid(),author uuid not null references public.unichat_profiles(id),title text not null check(length(trim(title)) between 2 and 120),body text not null check(length(trim(body)) between 2 and 2000),link text check(link is null or link ~ '^https?://[^[:space:]]+$'),skills text[] not null default '{}',looking_for text not null default '' check(length(looking_for)<=300),created_at timestamptz not null default now());
create or replace function public.unichat_save_collaboration(payload jsonb) returns void language plpgsql security definer set search_path='' as $$
declare r public.unichat_collaboration;begin
 if not public.unichat_active() then raise exception 'An active account is required';end if;
 select * into r from jsonb_populate_record(null::public.unichat_collaboration,payload);
 insert into public.unichat_collaboration(user_id,interests,skills,courses,goals,study_days,study_periods,study_mode,open_to_study,discoverable,about)
 values(auth.uid(),coalesce(r.interests,'{}'),coalesce(r.skills,'{}'),coalesce(r.courses,'{}'),coalesce(r.goals,'{}'),coalesce(r.study_days,'{}'),coalesce(r.study_periods,'{}'),coalesce(r.study_mode,'either'),coalesce(r.open_to_study,false),coalesce(r.discoverable,true),coalesce(r.about,''))
 on conflict(user_id) do update set interests=excluded.interests,skills=excluded.skills,courses=excluded.courses,goals=excluded.goals,study_days=excluded.study_days,study_periods=excluded.study_periods,study_mode=excluded.study_mode,open_to_study=excluded.open_to_study,discoverable=excluded.discoverable,about=excluded.about;
end$$;
create or replace function public.unichat_common_tags(a text[],b text[]) returns integer language sql immutable set search_path='' as $$select count(distinct lower(trim(x)))::int from unnest(coalesce(a,'{}'))x where lower(trim(x)) in(select lower(trim(y)) from unnest(coalesce(b,'{}'))y) and trim(x)<>''$$;
create or replace function public.unichat_student_suggestions(study_only boolean default false,page_offset integer default 0) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare mine public.unichat_collaboration;preferences public.unichat_user_settings;profile jsonb;begin
 if not public.unichat_active() then raise exception 'Sign in to continue';end if;if not public.unichat_feature('suggestions') or (study_only and not public.unichat_feature('study_matching')) then raise exception 'Suggestions are currently paused';end if;
 select * into mine from public.unichat_collaboration where user_id=auth.uid();select * into preferences from public.unichat_user_settings where user_id=auth.uid();select data into profile from public.unichat_profiles where id=auth.uid();
 return coalesce((select jsonb_agg(to_jsonb(r)) from(
 select p.id,p.username,p.data,c.interests,c.skills,c.courses,c.goals,c.study_days,c.study_periods,c.study_mode,c.open_to_study,
 (public.unichat_common_tags(c.interests,mine.interests)*6+public.unichat_common_tags(c.courses,mine.courses)*8+public.unichat_common_tags(c.goals,mine.goals)*3+case when p.data->>'school'=profile->>'school' then 3 else 0 end+case when p.data->>'department'=profile->>'department' then 5 else 0 end+case when p.data->>'level'=profile->>'level' then 1 else 0 end+case when public.unichat_common_tags(c.study_days,mine.study_days)>0 and public.unichat_common_tags(c.study_periods,mine.study_periods)>0 then 5 else 0 end) score,
 array_remove(array[case when p.data->>'school'=profile->>'school' then 'Same school' end,case when p.data->>'department'=profile->>'department' then 'Same department' end,case when public.unichat_common_tags(c.courses,mine.courses)>0 then 'Shared courses' end,case when public.unichat_common_tags(c.interests,mine.interests)>0 then 'Shared interests' end,case when public.unichat_common_tags(c.study_days,mine.study_days)>0 and public.unichat_common_tags(c.study_periods,mine.study_periods)>0 then 'Study times overlap' end],null) reasons
 from public.unichat_profiles p left join public.unichat_collaboration c on c.user_id=p.id where p.id<>auth.uid() and public.unichat_profile_visible(p.id) and coalesce(c.discoverable,true)
 and (not study_only or (c.open_to_study and (mine.study_mode is null or mine.study_mode='either' or c.study_mode='either' or mine.study_mode=c.study_mode)))
 and (coalesce(preferences.preferred_school,'')='' or p.data->>'school'=preferences.preferred_school) and (coalesce(preferences.preferred_department,'')='' or p.data->>'department'=preferences.preferred_department)
 order by score desc,lower(p.data->>'name'),p.id limit 25 offset greatest(0,least(page_offset,100000))
 )r),'[]'::jsonb);
end$$;

create table if not exists public.unichat_hubs(id uuid primary key default gen_random_uuid(),creator uuid not null references public.unichat_profiles(id),school text not null check(length(trim(school)) between 2 and 150),department text not null check(length(trim(department)) between 2 and 150),course text not null default '' check(length(course)<=100),title text not null check(length(trim(title)) between 2 and 150),description text not null default '' check(length(description)<=1500),archived boolean not null default false,created_at timestamptz not null default now());
create unique index if not exists uc_hubs_course on public.unichat_hubs(lower(trim(school)),lower(trim(department)),lower(trim(course)));
create table if not exists public.unichat_hub_members(hub_id uuid not null references public.unichat_hubs(id) on delete cascade,user_id uuid not null references public.unichat_profiles(id),created_at timestamptz not null default now(),primary key(hub_id,user_id));
create table if not exists public.unichat_hub_posts(id uuid primary key default gen_random_uuid(),hub_id uuid not null references public.unichat_hubs(id) on delete cascade,author uuid not null references public.unichat_profiles(id),kind text not null check(kind in ('question','resource','discussion')),body text not null check(length(trim(body)) between 1 and 4000),resource_url text check(resource_url is null or resource_url ~ '^https?://[^[:space:]]+$'),created_at timestamptz not null default now());
create table if not exists public.unichat_hub_replies(id uuid primary key default gen_random_uuid(),post_id uuid not null references public.unichat_hub_posts(id) on delete cascade,author uuid not null references public.unichat_profiles(id),body text not null check(length(trim(body)) between 1 and 2000),created_at timestamptz not null default now());
create or replace function public.unichat_hub_member(target uuid) returns boolean language sql stable security definer set search_path='' as $$select public.unichat_active() and exists(select 1 from public.unichat_hub_members where hub_id=target and user_id=auth.uid())$$;
create or replace function public.unichat_hub_open(target uuid) returns boolean language sql stable security definer set search_path='' as $$select public.unichat_hub_member(target) and public.unichat_feature('hubs') and exists(select 1 from public.unichat_hubs where id=target and not archived)$$;
create or replace function public.unichat_hub_join(target uuid,join_hub boolean) returns void language plpgsql security definer set search_path='' as $$begin
 if not public.unichat_active() or not public.unichat_feature('hubs') then raise exception 'Hubs are unavailable';end if;
 if join_hub then if not exists(select 1 from public.unichat_hubs where id=target and not archived) then raise exception 'Hub unavailable';end if;insert into public.unichat_hub_members(hub_id,user_id) values(target,auth.uid()) on conflict do nothing;else delete from public.unichat_hub_members where hub_id=target and user_id=auth.uid();end if;
end$$;
create or replace function public.unichat_hub_identity_guard() returns trigger language plpgsql set search_path='' as $$
declare a jsonb;b jsonb;begin
 if tg_op='UPDATE' then a:=to_jsonb(new);b:=to_jsonb(old);if a->>'id' is distinct from b->>'id' or a->>'author' is distinct from b->>'author' or a->>'creator' is distinct from b->>'creator' or a->>'hub_id' is distinct from b->>'hub_id' or a->>'post_id' is distinct from b->>'post_id' or a->>'created_at' is distinct from b->>'created_at' then raise exception 'Record identity cannot change';end if;end if;return new;
end$$;

alter table public.unichat_listings add column if not exists levels text[] not null default '{}';alter table public.unichat_listings add column if not exists tags text[] not null default '{}';
create table if not exists public.unichat_saved_opportunities(user_id uuid not null references public.unichat_profiles(id),listing_id uuid not null references public.unichat_listings(id) on delete cascade,created_at timestamptz not null default now(),primary key(user_id,listing_id));
create or replace function public.unichat_opportunity_matches(saved_only boolean default false,page_offset integer default 0) returns jsonb language plpgsql security definer set search_path='' as $$
declare p jsonb;s public.unichat_user_settings;c public.unichat_collaboration;r record;inserted integer;begin
 if not public.unichat_active() then raise exception 'Sign in to continue';end if;perform public.unichat_my_settings();
 select data into p from public.unichat_profiles where id=auth.uid();select * into s from public.unichat_user_settings where user_id=auth.uid();select * into c from public.unichat_collaboration where user_id=auth.uid();
 if s.opportunity_reminders then for r in select l.* from public.unichat_saved_opportunities so join public.unichat_listings l on l.id=so.listing_id where so.user_id=auth.uid() and l.kind='opportunity' and l.status='open' and l.deadline>now() and l.deadline<=now()+interval '3 days' loop
  insert into public.unichat_reminder_events(user_id,kind,reference,period) values(auth.uid(),'opportunity_deadline',r.id::text,r.deadline::date::text) on conflict do nothing;get diagnostics inserted=row_count;
  if inserted=1 then insert into public.unichat_notifications(recipient,actor,kind,reference) values(auth.uid(),r.author,'opportunity_deadline',r.id::text);end if;
 end loop;end if;
 return coalesce((select jsonb_agg(to_jsonb(result)) from(select l.*,exists(select 1 from public.unichat_saved_opportunities where user_id=auth.uid() and listing_id=l.id) saved,
 public.unichat_common_tags(l.tags,c.interests)*3+public.unichat_common_tags(l.tags,c.skills)*3+case when l.school=p->>'school' then 5 else 0 end+case when l.department=p->>'department' then 5 else 0 end score
 from public.unichat_listings l where l.kind='opportunity' and l.status='open' and (l.deadline is null or l.deadline>now()) and
 (saved_only and exists(select 1 from public.unichat_saved_opportunities where user_id=auth.uid() and listing_id=l.id) or not saved_only and (l.school in ('Across schools','') or l.school=coalesce(nullif(s.preferred_school,''),p->>'school')) and (l.department='' or l.department=coalesce(nullif(s.preferred_department,''),p->>'department')) and (cardinality(l.levels)=0 or (p->>'level')=any(l.levels)))
 order by score desc,l.deadline nulls last,l.created_at desc,l.id limit 25 offset greatest(0,least(page_offset,100000)))result),'[]'::jsonb);
end$$;

-- Optional verification: exact institution email domains or explicit owner review.
alter table public.unichat_directory add column if not exists email_domains text[] not null default '{}';
create table if not exists public.unichat_verifications(user_id uuid primary key references public.unichat_profiles(id),school text not null,status text not null default 'pending' check(status in ('pending','approved','rejected')),method text not null default 'review' check(method in ('school_email','review')),note text not null default '' check(length(note)<=1500),proof_url text check(proof_url is null or proof_url ~ '^https?://[^[:space:]]+$'),review_note text not null default '' check(length(review_note)<=1500),reviewed_by uuid,created_at timestamptz not null default now(),reviewed_at timestamptz);
create or replace function public.unichat_request_verification(student_note text default '',evidence_url text default null) returns text language plpgsql security definer set search_path='' as $$
declare school_name text;verified boolean;begin
 if not public.unichat_active() then raise exception 'An active account is required';end if;select data->>'school' into school_name from public.unichat_profiles where id=auth.uid();
 select exists(select 1 from auth.users u join public.unichat_directory d on lower(trim(d.school))=lower(trim(school_name)) where u.id=auth.uid() and u.email_confirmed_at is not null and split_part(lower(u.email),'@',2)=any(d.email_domains) and d.active) into verified;
 insert into public.unichat_verifications(user_id,school,status,method,note,proof_url,reviewed_at) values(auth.uid(),school_name,case when verified then 'approved' else 'pending' end,case when verified then 'school_email' else 'review' end,student_note,nullif(trim(evidence_url),''),case when verified then now() else null end)
 on conflict(user_id) do update set school=excluded.school,status=excluded.status,method=excluded.method,note=excluded.note,proof_url=excluded.proof_url,review_note='',reviewed_by=null,reviewed_at=excluded.reviewed_at,created_at=now();
 return case when verified then 'approved' else 'pending' end;
end$$;
create or replace function public.unichat_review_verification(student_id uuid,approved boolean,review_message text) returns void language plpgsql security definer set search_path='' as $$begin
 if not public.unichat_is_owner() then raise exception 'Owner access required';end if;if length(trim(review_message))<2 then raise exception 'Record how you checked the affiliation';end if;
 update public.unichat_verifications set status=case when approved then 'approved' else 'rejected' end,method='review',review_note=review_message,reviewed_by=auth.uid(),reviewed_at=now() where user_id=student_id and school=(select data->>'school' from public.unichat_profiles where id=student_id);
 perform public.unichat_log('verification:review',student_id::text);
end$$;
create or replace function public.unichat_public_verification(student_ids uuid[]) returns jsonb language sql stable security definer set search_path='' as $$select coalesce(jsonb_agg(jsonb_build_object('id',v.user_id,'method',v.method,'school',v.school)),'[]'::jsonb) from public.unichat_verifications v join public.unichat_profiles p on p.id=v.user_id where v.user_id=any(student_ids[1:100]) and v.status='approved' and v.school=p.data->>'school' and public.unichat_profile_visible(p.id) and (v.method<>'school_email' or exists(select 1 from auth.users u join public.unichat_directory d on lower(trim(d.school))=lower(trim(v.school)) where u.id=v.user_id and u.email_confirmed_at is not null and d.active and split_part(lower(u.email),'@',2)=any(d.email_domains)))$$;
create or replace function public.unichat_school_domains(school_id uuid,domains text[]) returns void language plpgsql security definer set search_path='' as $$declare d text;begin
 if not public.unichat_is_owner() then raise exception 'Owner access required';end if;if cardinality(domains)>20 then raise exception 'Use at most 20 domains';end if;
 foreach d in array domains loop if d !~ '^[a-z0-9][a-z0-9.-]*\.[a-z]{2,}$' then raise exception 'Enter domain names without @ or URLs';end if;end loop;
 update public.unichat_directory set email_domains=domains where id=school_id;perform public.unichat_log('verification:domains',school_id::text);
end$$;

do $$declare t text;begin foreach t in array array['collaboration','projects','hubs','hub_members','hub_posts','hub_replies','saved_opportunities','verifications'] loop execute format('alter table public.%I enable row level security','unichat_'||t);end loop;end$$;
drop policy if exists uc_collab_read on public.unichat_collaboration;create policy uc_collab_read on public.unichat_collaboration for select to authenticated using(user_id=auth.uid() or public.unichat_profile_visible(user_id));
drop policy if exists uc_projects_read on public.unichat_projects;create policy uc_projects_read on public.unichat_projects for select to authenticated using(author=auth.uid() or public.unichat_profile_visible(author));
drop policy if exists uc_projects_own on public.unichat_projects;create policy uc_projects_own on public.unichat_projects for all to authenticated using(public.unichat_active() and author=auth.uid()) with check(public.unichat_active() and author=auth.uid());
drop policy if exists uc_hubs_read on public.unichat_hubs;create policy uc_hubs_read on public.unichat_hubs for select to authenticated using(public.unichat_active());
drop policy if exists uc_hubs_add on public.unichat_hubs;create policy uc_hubs_add on public.unichat_hubs for insert to authenticated with check(public.unichat_active() and creator=auth.uid() and public.unichat_feature('hubs'));
drop policy if exists uc_hubs_edit on public.unichat_hubs;create policy uc_hubs_edit on public.unichat_hubs for update to authenticated using(public.unichat_active() and (creator=auth.uid() or public.unichat_is_owner())) with check(public.unichat_active() and (creator=auth.uid() or public.unichat_is_owner()));
drop policy if exists uc_hub_members_read on public.unichat_hub_members;create policy uc_hub_members_read on public.unichat_hub_members for select to authenticated using(user_id=auth.uid() or public.unichat_hub_member(hub_id));
drop policy if exists uc_hub_posts_read on public.unichat_hub_posts;create policy uc_hub_posts_read on public.unichat_hub_posts for select to authenticated using(public.unichat_hub_member(hub_id));
drop policy if exists uc_hub_posts_add on public.unichat_hub_posts;create policy uc_hub_posts_add on public.unichat_hub_posts for insert to authenticated with check(author=auth.uid() and public.unichat_hub_open(hub_id));
drop policy if exists uc_hub_posts_own on public.unichat_hub_posts;create policy uc_hub_posts_own on public.unichat_hub_posts for update to authenticated using(author=auth.uid() and public.unichat_hub_open(hub_id)) with check(author=auth.uid() and public.unichat_hub_open(hub_id));
drop policy if exists uc_hub_posts_remove on public.unichat_hub_posts;create policy uc_hub_posts_remove on public.unichat_hub_posts for delete to authenticated using(public.unichat_active() and (author=auth.uid() or public.unichat_is_owner()));
drop policy if exists uc_hub_reply_read on public.unichat_hub_replies;create policy uc_hub_reply_read on public.unichat_hub_replies for select to authenticated using(exists(select 1 from public.unichat_hub_posts p where p.id=post_id and public.unichat_hub_member(p.hub_id)));
drop policy if exists uc_hub_reply_add on public.unichat_hub_replies;create policy uc_hub_reply_add on public.unichat_hub_replies for insert to authenticated with check(author=auth.uid() and exists(select 1 from public.unichat_hub_posts p where p.id=post_id and public.unichat_hub_open(p.hub_id)));
drop policy if exists uc_hub_reply_remove on public.unichat_hub_replies;create policy uc_hub_reply_remove on public.unichat_hub_replies for delete to authenticated using(public.unichat_active() and (author=auth.uid() or public.unichat_is_owner()));
drop policy if exists uc_saved_opportunities_own on public.unichat_saved_opportunities;create policy uc_saved_opportunities_own on public.unichat_saved_opportunities for all to authenticated using(user_id=auth.uid() and public.unichat_active()) with check(user_id=auth.uid() and public.unichat_active());
drop policy if exists uc_verification_read on public.unichat_verifications;create policy uc_verification_read on public.unichat_verifications for select to authenticated using(user_id=auth.uid() or public.unichat_is_owner());
grant select on public.unichat_collaboration,public.unichat_hub_members,public.unichat_verifications to authenticated;
grant select,insert,update,delete on public.unichat_projects,public.unichat_hubs,public.unichat_hub_posts,public.unichat_hub_replies,public.unichat_saved_opportunities to authenticated;
do $$declare t text;begin foreach t in array array['unichat_hubs','unichat_hub_posts','unichat_hub_replies','unichat_projects'] loop execute format('drop trigger if exists uc_identity_guard on public.%I',t);execute format('create trigger uc_identity_guard before update on public.%I for each row execute function public.unichat_hub_identity_guard()',t);end loop;end$$;
revoke all on function public.unichat_hub_identity_guard() from public,anon,authenticated;
do $$declare signature text;begin foreach signature in array array['unichat_save_collaboration(jsonb)','unichat_common_tags(text[],text[])','unichat_student_suggestions(boolean,integer)','unichat_hub_member(uuid)','unichat_hub_open(uuid)','unichat_hub_join(uuid,boolean)','unichat_opportunity_matches(boolean,integer)','unichat_request_verification(text,text)','unichat_review_verification(uuid,boolean,text)','unichat_public_verification(uuid[])','unichat_school_domains(uuid,text[])'] loop execute 'revoke all on function public.'||signature||' from public,anon';execute 'grant execute on function public.'||signature||' to authenticated';end loop;end$$;

-- UniChat_Update_10.sql
-- Inline comments/replies/reactions and improved one-to-one conversation state.
alter table public.unichat_post_replies add column if not exists edited_at timestamptz;
alter table public.unichat_reel_comments add column if not exists edited_at timestamptz;
create table if not exists public.unichat_reel_replies(id uuid primary key default gen_random_uuid(),comment_id uuid not null references public.unichat_reel_comments(id) on delete cascade,author uuid not null references public.unichat_profiles(id),body text not null check(length(trim(body)) between 1 and 2000),created_at timestamptz not null default now(),edited_at timestamptz);
create table if not exists public.unichat_comment_reactions(target_kind text not null check(target_kind in ('comment','reply','reel_comment','reel_reply')),target_id text not null,user_id uuid not null references public.unichat_profiles(id),created_at timestamptz not null default now(),primary key(target_kind,target_id,user_id));
create or replace function public.unichat_comment_visible(kind_name text,record_id text) returns boolean language sql stable security definer set search_path='' as $$select public.unichat_active() and case
 when kind_name='comment' then exists(select 1 from public.unichat_content c where c.id=record_id and c.kind='comment' and public.unichat_post_visible(c.data->>'postId'))
 when kind_name='reply' then exists(select 1 from public.unichat_post_replies r join public.unichat_content c on c.id=r.comment_id where r.id::text=record_id and public.unichat_post_visible(c.data->>'postId'))
 when kind_name='reel_comment' then exists(select 1 from public.unichat_reel_comments c where c.id::text=record_id and public.unichat_media_visible(c.reel_id))
 when kind_name='reel_reply' then exists(select 1 from public.unichat_reel_replies r join public.unichat_reel_comments c on c.id=r.comment_id where r.id::text=record_id and public.unichat_media_visible(c.reel_id)) else false end$$;
create or replace function public.unichat_reaction_toggle(kind_name text,record_id text) returns jsonb language plpgsql security definer set search_path='' as $$
declare liked boolean;begin
 if not public.unichat_comment_visible(kind_name,record_id) or not public.unichat_feature('reactions') then raise exception 'This comment is unavailable';end if;
 delete from public.unichat_comment_reactions where target_kind=kind_name and target_id=record_id and user_id=auth.uid();
 if not found then insert into public.unichat_comment_reactions(target_kind,target_id,user_id) values(kind_name,record_id,auth.uid());liked:=true;else liked:=false;end if;
 return jsonb_build_object('liked',liked,'count',(select count(*) from public.unichat_comment_reactions where target_kind=kind_name and target_id=record_id));
end$$;
create or replace function public.unichat_comment_json(kind_name text,record_id text,author_id uuid,body text,created timestamptz,edited timestamptz) returns jsonb language sql stable security definer set search_path='' as $$select jsonb_build_object('kind',kind_name,'id',record_id,'author',author_id,'name',coalesce((select data->>'name' from public.unichat_profiles where id=author_id),'Student'),'avatar_path',(select data->>'avatar_path' from public.unichat_profiles where id=author_id),'body',body,'created_at',created,'edited_at',edited,'likes',(select count(*) from public.unichat_comment_reactions where target_kind=kind_name and target_id=record_id),'liked',exists(select 1 from public.unichat_comment_reactions where target_kind=kind_name and target_id=record_id and user_id=auth.uid()))$$;
create or replace function public.unichat_thread_page(parent_kind text,parent_id text,page_offset integer default 0) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb;total bigint;begin
 if parent_kind='post' then
  if not public.unichat_post_visible(parent_id) then raise exception 'Post unavailable';end if;
  select count(*) into total from public.unichat_content where kind='comment' and data->>'postId'=parent_id;
  select coalesce(jsonb_agg(public.unichat_comment_json('comment',c.id,c.owner,c.data->>'text',c.created_at,(c.data->>'edited_at')::timestamptz)||jsonb_build_object('reply_count',(select count(*) from public.unichat_post_replies where comment_id=c.id))),'[]') into result from(select * from public.unichat_content where kind='comment' and data->>'postId'=parent_id order by created_at,id limit 20 offset greatest(0,page_offset))c;
 elsif parent_kind='reel' then
  if not public.unichat_media_visible(parent_id::uuid) then raise exception 'Reel unavailable';end if;
  select count(*) into total from public.unichat_reel_comments where reel_id=parent_id::uuid;
  select coalesce(jsonb_agg(public.unichat_comment_json('reel_comment',c.id::text,c.author,c.body,c.created_at,c.edited_at)||jsonb_build_object('reply_count',(select count(*) from public.unichat_reel_replies where comment_id=c.id))),'[]') into result from(select * from public.unichat_reel_comments where reel_id=parent_id::uuid order by created_at,id limit 20 offset greatest(0,page_offset))c;
 else raise exception 'Unknown thread';end if;
 return jsonb_build_object('rows',result,'total',total);
end$$;
create or replace function public.unichat_reply_page(kind_name text,comment_id text,page_offset integer default 0) returns jsonb language plpgsql stable security definer set search_path='' as $$declare result jsonb;total bigint;begin
 if not public.unichat_comment_visible(kind_name,comment_id) then raise exception 'Comment unavailable';end if;
 if kind_name='comment' then
  select count(*) into total from public.unichat_post_replies r where r.comment_id=unichat_reply_page.comment_id;
  select coalesce(jsonb_agg(public.unichat_comment_json('reply',r.id::text,r.author,r.body,r.created_at,r.edited_at)),'[]') into result from(select * from public.unichat_post_replies r where r.comment_id=unichat_reply_page.comment_id order by created_at,id limit 20 offset greatest(0,page_offset))r;
 elsif kind_name='reel_comment' then
  select count(*) into total from public.unichat_reel_replies r where r.comment_id::text=unichat_reply_page.comment_id;
  select coalesce(jsonb_agg(public.unichat_comment_json('reel_reply',r.id::text,r.author,r.body,r.created_at,r.edited_at)),'[]') into result from(select * from public.unichat_reel_replies r where r.comment_id::text=unichat_reply_page.comment_id order by created_at,id limit 20 offset greatest(0,page_offset))r;
 else raise exception 'Unknown reply target';end if;return jsonb_build_object('rows',result,'total',total);
end$$;
create or replace function public.unichat_send_comment(parent_kind text,parent_id text,body text,is_reply boolean default false) returns text language plpgsql security definer set search_path='' as $$declare new_id text;target uuid;ref text;begin
 if not public.unichat_active() or not public.unichat_feature('comments') then raise exception 'Comments are unavailable';end if;
 if length(trim(body)) not between 1 and 2000 then raise exception 'Write a comment of up to 2000 characters';end if;
 if not is_reply and parent_kind='post' then if not public.unichat_post_visible(parent_id) then raise exception 'Post unavailable';end if;new_id:=gen_random_uuid()::text;insert into public.unichat_content(id,owner,kind,data) values(new_id,auth.uid(),'comment',jsonb_build_object('postId',parent_id,'text',trim(body)));
 elsif not is_reply and parent_kind='reel' then if not public.unichat_media_visible(parent_id::uuid) then raise exception 'Reel unavailable';end if;insert into public.unichat_reel_comments(reel_id,author,body) values(parent_id::uuid,auth.uid(),trim(body)) returning id::text into new_id;select author into target from public.unichat_media where id=parent_id::uuid;perform public.unichat_notify(target,'reel_comment',parent_id);
 elsif is_reply and parent_kind='comment' then if not public.unichat_comment_visible('comment',parent_id) then raise exception 'Comment unavailable';end if;insert into public.unichat_post_replies(comment_id,author,body) values(parent_id,auth.uid(),trim(body)) returning id::text into new_id;
 elsif is_reply and parent_kind='reel_comment' then if not public.unichat_comment_visible('reel_comment',parent_id) then raise exception 'Comment unavailable';end if;insert into public.unichat_reel_replies(comment_id,author,body) values(parent_id::uuid,auth.uid(),trim(body)) returning id::text into new_id;select author,reel_id::text into target,ref from public.unichat_reel_comments where id=parent_id::uuid;perform public.unichat_notify(target,'reel_reply',ref);
 else raise exception 'Unknown comment target';end if;return new_id;
end$$;
create or replace function public.unichat_edit_my_item(kind_name text,record_id text,body text,audience text default null) returns void language plpgsql security definer set search_path='' as $$begin
 if not public.unichat_active() then raise exception 'An active account is required';end if;
 if kind_name='post' then
  if not exists(select 1 from public.unichat_content where id=record_id and kind='post' and owner=auth.uid()) then raise exception 'You can edit only your own post';end if;
  update public.unichat_content set data=data||jsonb_build_object('text',trim(body),'edited_at',now(),'audience',coalesce(audience,data->>'audience','students')) where id=record_id;
 elsif kind_name='comment' then
  if not exists(select 1 from public.unichat_content where id=record_id and kind='comment' and owner=auth.uid()) then raise exception 'You can edit only your own comment';end if;
  update public.unichat_content set data=data||jsonb_build_object('text',trim(body),'edited_at',now()) where id=record_id;
 elsif kind_name='reply' then update public.unichat_post_replies set body=trim(unichat_edit_my_item.body),edited_at=now() where id::text=record_id and author=auth.uid();if not found then raise exception 'You can edit only your own reply';end if;
 elsif kind_name='reel_comment' then update public.unichat_reel_comments set body=trim(unichat_edit_my_item.body),edited_at=now() where id::text=record_id and author=auth.uid();if not found then raise exception 'You can edit only your own comment';end if;
 elsif kind_name='reel_reply' then update public.unichat_reel_replies set body=trim(unichat_edit_my_item.body),edited_at=now() where id::text=record_id and author=auth.uid();if not found then raise exception 'You can edit only your own reply';end if;
 else raise exception 'Unknown item';end if;
end$$;
create or replace function public.unichat_delete_my_item(kind_name text,record_id text) returns void language plpgsql security definer set search_path='' as $$begin
 if not public.unichat_active() then raise exception 'An active account is required';end if;
 if kind_name='post' then
  if not exists(select 1 from public.unichat_content where id=record_id and kind='post' and owner=auth.uid()) then raise exception 'You can delete only your own post';end if;
  delete from public.unichat_post_replies where comment_id in(select id from public.unichat_content where kind='comment' and data->>'postId'=record_id);
  delete from public.unichat_content where kind in ('comment','like') and data->>'postId'=record_id;delete from public.unichat_content where id=record_id;
 elsif kind_name='comment' then
  if not exists(select 1 from public.unichat_content where id=record_id and kind='comment' and owner=auth.uid()) then raise exception 'You can delete only your own comment';end if;
  delete from public.unichat_post_replies where comment_id=record_id;delete from public.unichat_content where id=record_id;
 elsif kind_name='reply' then delete from public.unichat_post_replies where id::text=record_id and author=auth.uid();if not found then raise exception 'You can delete only your own reply';end if;
 elsif kind_name='reel_comment' then delete from public.unichat_reel_comments where id::text=record_id and author=auth.uid();if not found then raise exception 'You can delete only your own comment';end if;
 elsif kind_name='reel_reply' then delete from public.unichat_reel_replies where id::text=record_id and author=auth.uid();if not found then raise exception 'You can delete only your own reply';end if;
 else raise exception 'Unknown item';end if;
end$$;
create or replace function public.unichat_clean_comment_reactions() returns trigger language plpgsql security definer set search_path='' as $$declare kind_name text;begin
 kind_name:=case tg_table_name when 'unichat_content' then 'comment' when 'unichat_post_replies' then 'reply' when 'unichat_reel_comments' then 'reel_comment' else 'reel_reply' end;
 delete from public.unichat_comment_reactions where target_kind=kind_name and target_id=old.id::text;return old;
end$$;
do $$declare t text;begin foreach t in array array['unichat_content','unichat_post_replies','unichat_reel_comments','unichat_reel_replies'] loop execute format('drop trigger if exists uc_clean_comment_reactions on public.%I',t);execute format('create trigger uc_clean_comment_reactions after delete on public.%I for each row execute function public.unichat_clean_comment_reactions()',t);end loop;end$$;
create or replace function public.unichat_post_counts(post_ids text[]) returns jsonb language sql stable security definer set search_path='' as $$select coalesce(jsonb_object_agg(c.id,jsonb_build_object('likes',(select count(*) from public.unichat_content l where l.kind='like' and l.data->>'postId'=c.id),'comments',(select count(*) from public.unichat_content x where x.kind='comment' and x.data->>'postId'=c.id)+(select count(*) from public.unichat_post_replies r join public.unichat_content x on x.id=r.comment_id where x.data->>'postId'=c.id))),'{}') from public.unichat_content c where c.id=any(post_ids[1:100]) and c.kind='post' and public.unichat_post_visible(c.id)$$;

create table if not exists public.unichat_message_receipts(user_id uuid not null references public.unichat_profiles(id),peer uuid not null references public.unichat_profiles(id),delivered_at timestamptz,read_at timestamptz,primary key(user_id,peer),check(user_id<>peer));
create table if not exists public.unichat_typing(sender uuid not null references public.unichat_profiles(id),recipient uuid not null references public.unichat_profiles(id),typed_at timestamptz not null default now(),primary key(sender,recipient),check(sender<>recipient));
create or replace function public.unichat_chat_signal(peer_id uuid,signal_name text) returns void language plpgsql security definer set search_path='' as $$begin
 if not public.unichat_active() or not exists(select 1 from public.unichat_contacts where status='accepted' and ((sender=auth.uid() and recipient=peer_id) or (recipient=auth.uid() and sender=peer_id))) then raise exception 'Conversation unavailable';end if;
 if signal_name='typing' then if not public.unichat_can_contact(peer_id) then return;end if;insert into public.unichat_typing(sender,recipient,typed_at) values(auth.uid(),peer_id,now()) on conflict(sender,recipient) do update set typed_at=now();
 elsif signal_name='stop_typing' then delete from public.unichat_typing where sender=auth.uid() and recipient=peer_id;
 elsif signal_name in ('delivered','read') then insert into public.unichat_message_receipts(user_id,peer,delivered_at,read_at) values(auth.uid(),peer_id,now(),case when signal_name='read' then now() else null end) on conflict(user_id,peer) do update set delivered_at=now(),read_at=case when signal_name='read' then now() else unichat_message_receipts.read_at end;
 else raise exception 'Unknown signal';end if;
end$$;
create or replace function public.unichat_dm_state(peer_id uuid) returns jsonb language plpgsql stable security definer set search_path='' as $$begin
 if not public.unichat_active() or not exists(select 1 from public.unichat_contacts where status='accepted' and ((sender=auth.uid() and recipient=peer_id) or (recipient=auth.uid() and sender=peer_id))) then raise exception 'Conversation unavailable';end if;
 return jsonb_build_object('typing',public.unichat_peer_available(peer_id) and exists(select 1 from public.unichat_typing where sender=peer_id and recipient=auth.uid() and typed_at>now()-interval '6 seconds'),
 'online',case when public.unichat_peer_available(peer_id) and coalesce((select share_online from public.unichat_user_settings where user_id=peer_id),false) then exists(select 1 from public.unichat_presence where user_id=peer_id and last_seen>now()-interval '90 seconds') else null end,
 'delivered_at',(select delivered_at from public.unichat_message_receipts where user_id=peer_id and peer=auth.uid()),
 'read_at',case when coalesce((select read_receipts from public.unichat_user_settings where user_id=peer_id),false) and coalesce((select read_receipts from public.unichat_user_settings where user_id=auth.uid()),false) then(select read_at from public.unichat_message_receipts where user_id=peer_id and peer=auth.uid()) else null end);
end$$;
create or replace function public.unichat_conversation_unread() returns jsonb language plpgsql stable security definer set search_path='' as $$begin
 if not public.unichat_active() then return '{}';end if;
 return coalesce((select jsonb_object_agg(peer_id::text,unread) from(select p.peer_id,
 (select count(*) from public.unichat_content c where c.kind='message' and c.owner=p.peer_id and c.data->>'recipient'=auth.uid()::text and c.created_at>coalesce(r.read_at,'1970-01-01'::timestamptz))+
 (select count(*) from public.unichat_voice_messages v where v.sender=p.peer_id and v.recipient=auth.uid() and v.created_at>coalesce(r.read_at,'1970-01-01'::timestamptz))+
 (select count(*) from public.unichat_attachments a where a.sender=p.peer_id and a.recipient=auth.uid() and a.created_at>coalesce(r.read_at,'1970-01-01'::timestamptz)) unread
 from(select case when sender=auth.uid() then recipient else sender end peer_id from public.unichat_contacts where status='accepted' and (sender=auth.uid() or recipient=auth.uid()))p left join public.unichat_message_receipts r on r.user_id=auth.uid() and r.peer=p.peer_id where public.unichat_peer_available(p.peer_id))counts),'{}');
end$$;
create or replace function public.unichat_search_messages(peer_id uuid,search_text text,page_offset integer default 0) returns jsonb language plpgsql stable security definer set search_path='' as $$begin
 if not public.unichat_active() or not exists(select 1 from public.unichat_contacts where status='accepted' and ((sender=auth.uid() and recipient=peer_id) or (recipient=auth.uid() and sender=peer_id))) then raise exception 'Conversation unavailable';end if;
 if length(trim(search_text))<1 then return '[]';end if;
 return coalesce((select jsonb_agg(to_jsonb(c)) from(select id,owner,data->>'text' body,created_at from public.unichat_content c where c.kind='message' and ((c.owner=auth.uid() and c.data->>'recipient'=peer_id::text) or (c.owner=peer_id and c.data->>'recipient'=auth.uid()::text)) and position(lower(left(trim(search_text),100)) in lower(c.data->>'text'))>0 order by created_at desc,id limit 25 offset greatest(0,page_offset))c),'[]');
end$$;

alter table public.unichat_reel_replies enable row level security;alter table public.unichat_comment_reactions enable row level security;alter table public.unichat_message_receipts enable row level security;alter table public.unichat_typing enable row level security;
drop policy if exists uc_reel_replies_read on public.unichat_reel_replies;create policy uc_reel_replies_read on public.unichat_reel_replies for select to authenticated using(public.unichat_comment_visible('reel_reply',id::text));
drop policy if exists uc_comment_reactions_read on public.unichat_comment_reactions;create policy uc_comment_reactions_read on public.unichat_comment_reactions for select to authenticated using(public.unichat_comment_visible(target_kind,target_id));
drop policy if exists uc_receipts_own_read on public.unichat_message_receipts;create policy uc_receipts_own_read on public.unichat_message_receipts for select to authenticated using(user_id=auth.uid() and public.unichat_active());
grant select on public.unichat_reel_replies,public.unichat_comment_reactions,public.unichat_message_receipts to authenticated;
revoke all on function public.unichat_comment_json(text,text,uuid,text,timestamptz,timestamptz),public.unichat_clean_comment_reactions() from public,anon,authenticated;
do $$declare signature text;begin foreach signature in array array['unichat_comment_visible(text,text)','unichat_reaction_toggle(text,text)','unichat_thread_page(text,text,integer)','unichat_reply_page(text,text,integer)','unichat_send_comment(text,text,text,boolean)','unichat_edit_my_item(text,text,text,text)','unichat_delete_my_item(text,text)','unichat_post_counts(text[])','unichat_chat_signal(uuid,text)','unichat_dm_state(uuid)','unichat_conversation_unread()','unichat_search_messages(uuid,text,integer)'] loop execute 'revoke all on function public.'||signature||' from public,anon';execute 'grant execute on function public.'||signature||' to authenticated';end loop;end$$;

-- UniChat_Update_11.sql
-- Self-service lifecycle and privacy-aware administrative tools.
alter table public.unichat_profiles drop constraint if exists unichat_profiles_status_check;
alter table public.unichat_profiles add constraint unichat_profiles_status_check check(status in ('active','suspended','deactivated'));
create table if not exists public.unichat_account_requests(user_id uuid primary key references public.unichat_profiles(id),requested_at timestamptz not null default now(),kind text not null default 'delete' check(kind='delete'));
alter table public.unichat_account_requests enable row level security;
drop policy if exists uc_account_request_read on public.unichat_account_requests;
create policy uc_account_request_read on public.unichat_account_requests for select to authenticated using(user_id=auth.uid() or public.unichat_is_owner());
grant select on public.unichat_account_requests to authenticated;
-- This table is only writable through the authenticated, fixed-purpose lifecycle RPC.
create or replace function public.unichat_account_action(action_name text,confirmation text default '') returns void language plpgsql security definer set search_path='' as $$
declare state text;begin
 if auth.uid() is null then raise exception 'Sign in to continue';end if;
 select status into state from public.unichat_profiles where id=auth.uid();
 if state is null then raise exception 'Account unavailable';end if;
 if public.unichat_owner_identity() then raise exception 'Transfer site ownership before deactivating this owner account';end if;
 if state='suspended' then raise exception 'Contact support about this suspension';end if;
 insert into public.unichat_lifecycle_ticket(user_id,transaction_id) values(auth.uid(),txid_current()) on conflict(user_id) do update set transaction_id=excluded.transaction_id;
 if action_name='reactivate' then
  if exists(select 1 from public.unichat_account_requests where user_id=auth.uid()) then raise exception 'Cancel your deletion request first';end if;
  update public.unichat_profiles set status='active' where id=auth.uid();
 elsif action_name='cancel_deletion' then
  delete from public.unichat_account_requests where user_id=auth.uid();update public.unichat_profiles set status='active' where id=auth.uid();
 elsif action_name in ('deactivate','request_deletion') then
  if action_name='request_deletion' then if confirmation<>'DELETE' then raise exception 'Type DELETE to request deletion';end if;insert into public.unichat_account_requests(user_id) values(auth.uid()) on conflict do nothing;end if;
  update public.unichat_profiles set status='deactivated' where id=auth.uid();delete from public.unichat_presence where user_id=auth.uid();
 else raise exception 'Unknown account action';end if;
 delete from public.unichat_lifecycle_ticket where user_id=auth.uid();
end$$;
-- A table-backed transition ticket cannot be forged through a client-set configuration variable.
create table if not exists public.unichat_lifecycle_ticket(user_id uuid primary key,transaction_id bigint not null);
revoke all on public.unichat_lifecycle_ticket from public,anon,authenticated;
create or replace function public.unichat_lifecycle_ticket_create() returns trigger language plpgsql security definer set search_path='' as $$begin return new;end$$;
create or replace function public.unichat_validate_profile() returns trigger language plpgsql security definer set search_path='' as $$begin
 if length(coalesce(new.data->>'name','')) not between 2 and 80 or trim(coalesce(new.data->>'school',''))='' or trim(coalesce(new.data->>'department',''))='' or trim(coalesce(new.data->>'level',''))='' then raise exception 'Complete all required profile fields';end if;
 new.username:=lower(new.username);new.data:=new.data||jsonb_build_object('username',new.username);
 if tg_op='INSERT' then
  if not public.unichat_site_open() or (not public.unichat_feature('registration') and not public.unichat_is_owner()) then raise exception 'Registration is paused';end if;
  if not public.unichat_is_owner() then new.status:='active';end if;
 else
  if new.id<>old.id then raise exception 'Profile identity cannot change';end if;
  if new.status<>old.status and not exists(select 1 from public.unichat_lifecycle_ticket where user_id=new.id and transaction_id=txid_current()) and not public.unichat_permission('moderate') then raise exception 'Moderation access required';end if;
  if old.status='deactivated' and not exists(select 1 from public.unichat_lifecycle_ticket where user_id=new.id and transaction_id=txid_current()) then raise exception 'Only this student may reactivate a deactivated account';end if;
  if new.id=auth.uid() and public.unichat_owner_identity() and new.status='suspended' then raise exception 'Owner cannot suspend own account';end if;
 end if;return new;
end$$;

create or replace function public.unichat_submit_report(kind_name text,record_id text,report_reason text,report_details text default '') returns uuid language plpgsql security definer set search_path='' as $$
declare snapshot jsonb;new_id uuid;begin
 if not public.unichat_active() then raise exception 'Sign in with an active account';end if;
 if (select count(*) from public.unichat_reports where reporter=auth.uid() and created_at>now()-interval '1 hour')>=20 then raise exception 'Please wait before sending more reports';end if;
 if kind_name in ('post','comment') then select to_jsonb(c) into snapshot from public.unichat_content c where id=record_id and kind=kind_name and public.unichat_post_visible(case when kind='post' then id else data->>'postId' end);
 elsif kind_name='reply' then select to_jsonb(r) into snapshot from public.unichat_post_replies r where id::text=record_id and public.unichat_comment_visible('reply',record_id);
 elsif kind_name='reel_comment' then select to_jsonb(c) into snapshot from public.unichat_reel_comments c where id::text=record_id and public.unichat_media_visible(c.reel_id);
 elsif kind_name='profile' then select jsonb_build_object('id',id,'username',username,'data',data) into snapshot from public.unichat_profiles where id::text=record_id and public.unichat_profile_visible(id);
 elsif kind_name in ('reel','story') then select to_jsonb(m)||jsonb_build_object('bucket','unichat-social-media') into snapshot from public.unichat_media m where id::text=record_id and kind=kind_name and public.unichat_media_visible(id);
 elsif kind_name='listing' then select to_jsonb(l) into snapshot from public.unichat_listings l where id::text=record_id;
 elsif kind_name='discussion' then select to_jsonb(d) into snapshot from public.unichat_discussions d where id::text=record_id and exists(select 1 from public.unichat_memberships where community_id=d.community_id and user_id=auth.uid());
 elsif kind_name='message' then select to_jsonb(c) into snapshot from public.unichat_content c where id=record_id and kind='message' and (owner=auth.uid() or data->>'recipient'=auth.uid()::text);
 elsif kind_name='voice' then select to_jsonb(v)||jsonb_build_object('bucket','unichat-voice') into snapshot from public.unichat_voice_messages v where id::text=record_id and (sender=auth.uid() or recipient=auth.uid());
 elsif kind_name='attachment' then select to_jsonb(a)||jsonb_build_object('bucket','unichat-chat-files') into snapshot from public.unichat_attachments a where id::text=record_id and (sender=auth.uid() or recipient=auth.uid() or public.unichat_group_member(chat_id));
 elsif kind_name='group_message' then select to_jsonb(m) into snapshot from public.unichat_chat_messages m where id::text=record_id and public.unichat_group_member(chat_id);
 elsif kind_name='reel_reply' then select to_jsonb(r) into snapshot from public.unichat_reel_replies r where id::text=record_id and public.unichat_comment_visible('reel_reply',record_id);
 elsif kind_name='hub_post' then select to_jsonb(p) into snapshot from public.unichat_hub_posts p where id::text=record_id and public.unichat_hub_member(hub_id);
 elsif kind_name='hub_reply' then select to_jsonb(r) into snapshot from public.unichat_hub_replies r where id::text=record_id and exists(select 1 from public.unichat_hub_posts p where p.id=r.post_id and public.unichat_hub_member(p.hub_id));
 else raise exception 'Unsupported report type';end if;
 if snapshot is null then raise exception 'This item is unavailable or is not part of your conversation';end if;
 insert into public.unichat_reports(reporter,target_kind,target_id,reason,details,evidence) values(auth.uid(),kind_name,record_id,report_reason,report_details,snapshot) returning id into new_id;return new_id;
end$$;

create or replace function public.unichat_media_visible(media_id uuid) returns boolean language sql stable security definer set search_path='' as $$select public.unichat_active() and exists(select 1 from public.unichat_media m where m.id=media_id and (m.kind='reel' or m.expires_at>now()) and public.unichat_profile_visible(m.author))$$;
create or replace function public.unichat_export_public() returns jsonb language plpgsql stable security definer set search_path='' as $$begin
 if not public.unichat_is_owner() then raise exception 'Owner access required';end if;
 return jsonb_build_object('format','unichat-visible-export-v2','exported_at',now(),
 'profiles',coalesce((select jsonb_agg(to_jsonb(p)) from public.unichat_profiles p where public.unichat_profile_visible(p.id)),'[]'),
 'settings',coalesce((select jsonb_agg(to_jsonb(s)) from public.unichat_settings s),'[]'),
 'content',coalesce((select jsonb_agg(to_jsonb(c)) from public.unichat_content c where c.kind in ('post','comment','like') and public.unichat_post_visible(case when c.kind='post' then c.id else c.data->>'postId' end)),'[]'),
 'communities',coalesce((select jsonb_agg(to_jsonb(g)) from public.unichat_communities g),'[]'),
 'events',coalesce((select jsonb_agg(to_jsonb(e)) from public.unichat_events e),'[]'),
 'media',coalesce((select jsonb_agg(to_jsonb(m)) from public.unichat_media m where public.unichat_media_visible(m.id)),'[]'),
 'listings',coalesce((select jsonb_agg(to_jsonb(l)) from public.unichat_listings l),'[]'),
 'announcements',coalesce((select jsonb_agg(to_jsonb(a)) from public.unichat_announcements a),'[]'),
 'directory',coalesce((select jsonb_agg(to_jsonb(d)) from public.unichat_directory d),'[]'));
end$$;
create or replace function public.unichat_export_mine() returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb;rows jsonb;t text;spec text;col text;begin
 if not public.unichat_active() then raise exception 'An active account is required';end if;
 result:=jsonb_build_object('format','unichat-personal-export-v1','exported_at',now(),'profile',(select to_jsonb(p) from public.unichat_profiles p where id=auth.uid()),'settings',(select to_jsonb(s) from public.unichat_user_settings s where user_id=auth.uid()),'collaboration',(select to_jsonb(c) from public.unichat_collaboration c where user_id=auth.uid()),'content',coalesce((select jsonb_agg(to_jsonb(c)) from public.unichat_content c where owner=auth.uid() or kind='message' and data->>'recipient'=auth.uid()::text),'[]'));
 foreach t in array array['voice_messages','attachments'] loop execute format('select coalesce(jsonb_agg(to_jsonb(x)),''[]'') from public.%I x where sender=auth.uid() or recipient=auth.uid()','unichat_'||t) into rows;result:=result||jsonb_build_object(t,rows);end loop;
 foreach spec in array array['collaboration:user_id','media:author','reel_comments:author','reel_replies:author','comment_reactions:user_id','post_replies:author','projects:author','saved_opportunities:user_id','verifications:user_id','hub_members:user_id','hub_posts:author','hub_replies:author'] loop t:=split_part(spec,':',1);col:=split_part(spec,':',2);execute format('select coalesce(jsonb_agg(to_jsonb(x)),''[]'') from public.%I x where %I=auth.uid()','unichat_'||t,col) into rows;result:=result||jsonb_build_object(t,rows);end loop;
 result:=result||jsonb_build_object('follows',coalesce((select jsonb_agg(to_jsonb(f)) from public.unichat_follows f where follower=auth.uid() or following=auth.uid()),'[]'),'contacts',coalesce((select jsonb_agg(to_jsonb(c)) from public.unichat_contacts c where sender=auth.uid() or recipient=auth.uid()),'[]'),'blocks',coalesce((select jsonb_agg(to_jsonb(b)) from public.unichat_blocks b where blocker=auth.uid()),'[]'),'group_messages',coalesce((select jsonb_agg(to_jsonb(m)) from public.unichat_chat_messages m where public.unichat_group_member(chat_id)),'[]'),'notifications',coalesce((select jsonb_agg(to_jsonb(n)) from public.unichat_notifications n where recipient=auth.uid()),'[]'));
 return result||jsonb_build_object('projects',coalesce((select jsonb_agg(to_jsonb(p)) from public.unichat_projects p where author=auth.uid()),'[]'),'note','Media metadata is included; download media separately. Other participants may retain their conversation copies.');
end$$;
revoke all on function public.unichat_lifecycle_ticket_create() from public,anon,authenticated;
revoke all on function public.unichat_account_action(text,text),public.unichat_export_mine() from public,anon;
grant execute on function public.unichat_account_action(text,text),public.unichat_export_mine() to authenticated;
create or replace function public.unichat_save_student_preferences(settings_payload jsonb,collaboration_payload jsonb) returns jsonb language plpgsql security definer set search_path='' as $$declare result jsonb;begin result:=public.unichat_save_my_settings(settings_payload);perform public.unichat_save_collaboration(collaboration_payload);return result;end$$;
revoke all on function public.unichat_save_student_preferences(jsonb,jsonb) from public,anon;grant execute on function public.unichat_save_student_preferences(jsonb,jsonb) to authenticated;

-- UniChat_Update_12.sql
-- Direct messages, privacy-aware active status and INSERT ... RETURNING post fix.
-- A new row is not visible to a STABLE helper's table snapshot during RETURNING.
-- The author branch uses the row directly; other viewers still use audience checks.
drop policy if exists unichat_content_read on public.unichat_content;
create policy unichat_content_read on public.unichat_content for select to authenticated using(public.unichat_active() and (
 (kind='post' and (owner=auth.uid() or public.unichat_post_visible(id))) or
 (kind in ('like','comment') and (owner=auth.uid() or public.unichat_post_visible(data->>'postId'))) or
 (kind='state' and owner=auth.uid()) or (kind='report' and public.unichat_is_owner()) or
 (kind='message' and (owner=auth.uid() or data->>'recipient'=auth.uid()::text))));
-- Internal lifecycle tickets never have a client read/write policy.
alter table public.unichat_lifecycle_ticket enable row level security;
revoke all on public.unichat_lifecycle_ticket from public,anon,authenticated;
create or replace function public.unichat_can_contact(peer uuid) returns boolean language sql stable security definer set search_path='' as $$select public.unichat_active() and public.unichat_feature('messaging') and public.unichat_message_allowed(peer)$$;
create or replace function public.unichat_guard_contact() returns trigger language plpgsql security definer set search_path='' as $$declare peer uuid;begin
 if tg_op='INSERT' then
  if new.sender<>auth.uid() or new.status not in ('pending','accepted') or not public.unichat_can_contact(new.recipient) then raise exception 'Messaging this student is unavailable';end if;
 else
  if new.id<>old.id or new.sender<>old.sender or new.recipient<>old.recipient or new.created_at<>old.created_at then raise exception 'Conversation identity cannot change';end if;
  peer:=case when old.sender=auth.uid() then old.recipient else old.sender end;
  if auth.uid() not in (old.sender,old.recipient) then raise exception 'Conversation participants only';end if;
  if new.status='accepted' then if not public.unichat_can_contact(peer) then raise exception 'Messaging this student is unavailable';end if;
  elsif new.status='declined' then if auth.uid()<>old.recipient then raise exception 'Only the recipient can decline';end if;
  else raise exception 'Invalid conversation state';end if;
 end if;return new;
end$$;
drop policy if exists uc_contacts_create on public.unichat_contacts;
create policy uc_contacts_create on public.unichat_contacts for insert to authenticated with check(public.unichat_active() and sender=auth.uid() and status in ('pending','accepted') and public.unichat_can_contact(recipient));
drop policy if exists uc_contacts_decide on public.unichat_contacts;
create policy uc_contacts_decide on public.unichat_contacts for update to authenticated using(public.unichat_active() and (sender=auth.uid() or recipient=auth.uid())) with check(public.unichat_active() and (sender=auth.uid() or recipient=auth.uid()) and status in ('accepted','declined'));
create or replace function public.unichat_open_conversation(peer uuid) returns uuid language plpgsql security definer set search_path='' as $$declare record_id uuid;begin
 if not public.unichat_can_contact(peer) then raise exception 'This student is unavailable or their messaging preferences do not allow this conversation';end if;
 -- Serialise each unordered pair so simultaneous first messages do not create duplicates.
 perform pg_advisory_xact_lock(hashtextextended(least(auth.uid(),peer)::text||greatest(auth.uid(),peer)::text,0));
 select id into record_id from public.unichat_contacts where (sender=auth.uid() and recipient=peer) or (sender=peer and recipient=auth.uid());
 if record_id is null then insert into public.unichat_contacts(sender,recipient,status) values(auth.uid(),peer,'accepted') returning id into record_id;
 else update public.unichat_contacts set status='accepted' where id=record_id and status<>'accepted';end if;return record_id;
end$$;
create or replace function public.unichat_online_status(student_ids uuid[]) returns jsonb language sql stable security definer set search_path='' as $$select coalesce(jsonb_object_agg(p.id::text,case when coalesce(s.share_online,false) then exists(select 1 from public.unichat_presence where user_id=p.id and last_seen>now()-interval '90 seconds') else null end),'{}') from public.unichat_profiles p left join public.unichat_user_settings s on s.user_id=p.id where public.unichat_active() and p.id=any(student_ids[1:100]) and public.unichat_profile_visible(p.id) and p.id<>auth.uid()$$;
create or replace function public.unichat_conversations(search_text text default '',page_offset integer default 0) returns jsonb language plpgsql stable security definer set search_path='' as $$begin
 if not public.unichat_active() then raise exception 'Sign in to continue';end if;
 return coalesce((select jsonb_agg(to_jsonb(result)) from(select p.id,p.username,case when public.unichat_profile_visible(p.id) then p.data else jsonb_build_object('name','Student','school','') end data,
 greatest(c.created_at,(select max(created_at) from public.unichat_content m where m.kind='message' and ((m.owner=p.id and m.data->>'recipient'=auth.uid()::text) or (m.owner=auth.uid() and m.data->>'recipient'=p.id::text))),(select max(created_at) from public.unichat_voice_messages v where (v.sender=p.id and v.recipient=auth.uid()) or (v.sender=auth.uid() and v.recipient=p.id)),(select max(created_at) from public.unichat_attachments a where (a.sender=p.id and a.recipient=auth.uid()) or (a.sender=auth.uid() and a.recipient=p.id))) last_activity,
 case when coalesce(s.share_online,false) and public.unichat_profile_visible(p.id) then exists(select 1 from public.unichat_presence where user_id=p.id and last_seen>now()-interval '90 seconds') else null end online
 from public.unichat_contacts c join public.unichat_profiles p on p.id=case when c.sender=auth.uid() then c.recipient else c.sender end left join public.unichat_user_settings s on s.user_id=p.id
 where (c.sender=auth.uid() or c.recipient=auth.uid()) and public.unichat_peer_available(p.id) and (trim(search_text)='' or public.unichat_profile_visible(p.id) and position(lower(left(trim(search_text),100)) in lower(concat_ws(' ',p.username,p.data->>'name',p.data->>'school')))>0)
 order by last_activity desc,p.id limit 25 offset greatest(0,least(page_offset,100000)))result),'[]');
end$$;
-- Index the chronological feed used by comments and direct conversation history.
create index if not exists uc_comment_post_date on public.unichat_content((data->>'postId'),created_at,id) where kind='comment';
revoke all on function public.unichat_open_conversation(uuid),public.unichat_online_status(uuid[]),public.unichat_conversations(text,integer) from public,anon;
grant execute on function public.unichat_open_conversation(uuid),public.unichat_online_status(uuid[]),public.unichat_conversations(text,integer) to authenticated;
commit;
