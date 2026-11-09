-- Reels, 24-hour Stories and profile covers. Included in the combined upgrade.
begin;
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
commit;
