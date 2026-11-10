-- Update 14: staged conversations and owner-selected upload sizes. No RLS is disabled.
begin;
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
  if size_limit is null or size_limit<1024 or size_limit>9007199254740991 or coalesce(cardinality(types),0)=0 or not types<@allowed then raise exception 'Invalid upload limit or type';end if;
  if bucket in ('unichat-social-media','unichat-voice') and ((v->>'seconds')::numeric is null or (v->>'seconds')::numeric<1 or (v->>'seconds')::numeric>60) then raise exception 'Video/voice duration must be 1–60 seconds';end if;
  update storage.buckets set file_size_limit=size_limit,allowed_mime_types=types where id=bucket;
 end loop;
 update public.unichat_control set maintenance=coalesce((payload->>'maintenance')::boolean,maintenance),maintenance_message=coalesce(nullif(trim(payload->>'message'),''),maintenance_message),owner_mfa=coalesce((payload->>'owner_mfa')::boolean,owner_mfa),upload_limits=merged where id='main';
end$$;

alter table public.unichat_attachments alter column size_bytes type bigint;
alter table public.unichat_media alter column size_bytes type bigint;
-- Remove only legacy byte ceilings, preserving unrelated validation.
do $$declare r record;begin
 for r in select conrelid::regclass tab,conname from pg_constraint where contype='c' and conrelid in ('public.unichat_media'::regclass,'public.unichat_attachments'::regclass) and pg_get_constraintdef(oid) like '%size_bytes%' loop
 execute format('alter table %s drop constraint %I',r.tab,r.conname);
 end loop;
end$$;
alter table public.unichat_attachments add constraint uc_attachment_positive_size check(size_bytes between 1 and 9007199254740991);
alter table public.unichat_media add constraint uc_media_positive_size check(size_bytes between 1 and 9007199254740991);
alter table public.unichat_media drop constraint if exists uc_media_shape;
alter table public.unichat_media add constraint uc_media_shape check(
 (kind='reel' and mime_type like 'video/%' and duration_seconds>0 and expires_at is null) or
 (kind='story' and expires_at is not null and ((mime_type like 'image/%' and duration_seconds=0) or (mime_type like 'video/%' and duration_seconds>0))));
create or replace function public.unichat_upload_size_guard() returns trigger language plpgsql security definer set search_path='' as $$
declare bucket text; ceiling bigint; actual bigint; declared bigint; meta jsonb;begin
 bucket:=case tg_table_name when 'unichat_media' then 'unichat-social-media' when 'unichat_attachments' then 'unichat-chat-files' else 'unichat-voice' end;
 select file_size_limit into ceiling from storage.buckets where id=bucket;
 select metadata into meta from storage.objects where bucket_id=bucket and name=new.storage_path;
 actual:=(meta->>'size')::bigint;
 declared:=(to_jsonb(new)->>'size_bytes')::bigint;
 if coalesce(declared,actual,1)<=0 or greatest(coalesce(actual,0),coalesce(declared,0))>ceiling then raise exception 'This file exceeds the owner upload limit';end if;
 if actual is not null and declared is not null and actual<>declared then raise exception 'Media size does not match the stored upload';end if;
 return new;
end$$;
revoke all on function public.unichat_upload_size_guard() from public,anon,authenticated;
do $$declare t text;begin foreach t in array array['unichat_media','unichat_attachments','unichat_voice_messages'] loop
 execute format('drop trigger if exists uc_upload_size_guard on public.%I',t);
 execute format('create trigger uc_upload_size_guard before insert on public.%I for each row execute function public.unichat_upload_size_guard()',t);
 end loop;
end$$;
-- Reapply the saved choices after earlier idempotent migrations.
do $$declare bucket text;v jsonb;begin for bucket,v in select * from jsonb_each((select upload_limits from public.unichat_control where id='main')) loop
 update storage.buckets set file_size_limit=(v->>'bytes')::bigint,allowed_mime_types=array(select jsonb_array_elements_text(v->'types')) where id=bucket;
end loop;end$$;
create index if not exists uc_dm_received_cursor on public.unichat_content((data->>'recipient'),owner,created_at desc,id desc) where kind='message';
create index if not exists uc_dm_voice_received_cursor on public.unichat_voice_messages(recipient,sender,created_at desc,id desc);
create index if not exists uc_dm_file_received_cursor on public.unichat_attachments(recipient,sender,created_at desc,id desc) where chat_id is null;
create index if not exists uc_dm_voice_sent_cursor on public.unichat_voice_messages(sender,recipient,created_at desc,id desc);
create index if not exists uc_dm_file_sent_cursor on public.unichat_attachments(sender,recipient,created_at desc,id desc) where chat_id is null;
create or replace function public.unichat_conversation_page(peer_id uuid,before_time timestamptz default null,before_key text default null) returns jsonb
language plpgsql security invoker set search_path='' as $$
declare allowed boolean; items jsonb; profile jsonb;begin
 if not public.unichat_active() or peer_id=auth.uid() then raise exception 'Conversation unavailable';end if;
 allowed:=public.unichat_can_contact(peer_id);
 if allowed and before_time is null then perform public.unichat_open_conversation(peer_id);end if;
 select jsonb_build_object('id',id,'username',username,'data',jsonb_build_object('name',data->>'name','school',data->>'school','avatar_path',data->>'avatar_path')) into profile from public.unichat_profiles where id=peer_id;
 with timeline as (
 (select 'message:'||id key,created_at,'message' kind,to_jsonb(c) row from public.unichat_content c where kind='message' and owner=auth.uid() and data->>'recipient'=peer_id::text and (before_time is null or (created_at,'message:'||id)<(before_time,before_key)) order by created_at desc,id desc limit 31)
 union all
 (select 'message:'||id key,created_at,'message' kind,to_jsonb(c) row from public.unichat_content c where kind='message' and owner=peer_id and data->>'recipient'=auth.uid()::text and (before_time is null or (created_at,'message:'||id)<(before_time,before_key)) order by created_at desc,id desc limit 31)
 union all
 (select 'voice:'||id key,created_at,'voice' kind,to_jsonb(v) row from public.unichat_voice_messages v where sender=auth.uid() and recipient=peer_id and (before_time is null or (created_at,'voice:'||id)<(before_time,before_key)) order by created_at desc,id desc limit 31)
 union all
 (select 'voice:'||id key,created_at,'voice' kind,to_jsonb(v) row from public.unichat_voice_messages v where sender=peer_id and recipient=auth.uid() and (before_time is null or (created_at,'voice:'||id)<(before_time,before_key)) order by created_at desc,id desc limit 31)
 union all
 (select 'attachment:'||id key,created_at,'attachment' kind,to_jsonb(a) row from public.unichat_attachments a where chat_id is null and sender=auth.uid() and recipient=peer_id and (before_time is null or (created_at,'attachment:'||id)<(before_time,before_key)) order by created_at desc,id desc limit 31)
 union all
 (select 'attachment:'||id key,created_at,'attachment' kind,to_jsonb(a) row from public.unichat_attachments a where chat_id is null and sender=peer_id and recipient=auth.uid() and (before_time is null or (created_at,'attachment:'||id)<(before_time,before_key)) order by created_at desc,id desc limit 31) ), batch as (select * from timeline where before_time is null or (created_at,key)<(before_time,before_key) order by created_at desc,key desc limit 31)
 select coalesce(jsonb_agg(to_jsonb(batch) order by created_at desc,key desc),'[]') into items from batch;
 return jsonb_build_object('allowed',allowed,'peer',profile,'items',items,'quotes',coalesce((
 select jsonb_object_agg(c.id,left(c.data->>'text',200)) from public.unichat_content c
 where c.kind='message' and c.id in (select i->'row'->'data'->>'reply_id' from jsonb_array_elements(items) i)
 and ((c.owner=auth.uid() and c.data->>'recipient'=peer_id::text) or (c.owner=peer_id and c.data->>'recipient'=auth.uid()::text))),'{}'::jsonb));
end$$;
revoke all on function public.unichat_conversation_page(uuid,timestamptz,text) from public,anon;
grant execute on function public.unichat_conversation_page(uuid,timestamptz,text) to authenticated;
commit;
