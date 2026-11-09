-- UniChat update 03: participant-private voice notes and student discovery.
-- Run after UniChat_Setup.sql and UniChat_Update_02.sql.
begin;
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
commit;
