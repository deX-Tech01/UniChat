-- UniChat Supabase setup. Run the entire file in Supabase SQL Editor.
-- Uses only UniChat-prefixed objects. Safe to rerun for this initial schema.
begin;
create table if not exists public.unichat_profiles (
 id uuid primary key references auth.users(id) on delete cascade,
 username text not null unique check(username ~ '^[a-z0-9_]{3,30}$'),
 data jsonb not null,
 status text not null default 'active' check(status in ('active','suspended')),
 created_at timestamptz not null default now(),
 constraint unichat_name_required check(length(trim(data->>'name')) between 2 and 80),
 constraint unichat_profile_required check(coalesce(data->>'school','')<>'' and coalesce(data->>'department','')<>'' and coalesce(data->>'level','')<>'')
);
create table if not exists public.unichat_content (
 id text primary key check(id ~ '^[a-zA-Z0-9:_-]{1,150}$'),
 owner uuid not null references auth.users(id) on delete cascade,
 kind text not null check(kind in ('state','post','like','comment','report','message')),
 data jsonb not null,
 created_at timestamptz not null default now()
);
create index if not exists unichat_content_kind_created on public.unichat_content(kind,created_at desc);
create index if not exists unichat_content_owner on public.unichat_content(owner);
create index if not exists unichat_content_recipient on public.unichat_content((data->>'recipient')) where kind='message';
create table if not exists public.unichat_settings(id text primary key check(id in ('published','draft')),data jsonb not null);
create table if not exists public.unichat_versions(id uuid primary key default gen_random_uuid(),data jsonb not null,created timestamptz not null default now());

create or replace function public.unichat_is_owner() returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from auth.users where id=auth.uid() and lower(email)='chimdike247@gmail.com' and email_confirmed_at is not null)
$$;
create or replace function public.unichat_active() returns boolean language sql stable security definer set search_path='' as $$
 select public.unichat_is_owner() or exists(select 1 from public.unichat_profiles where id=auth.uid() and status='active')
$$;
create or replace function public.unichat_feature(feature text) returns boolean language sql stable security definer set search_path='' as $$
 select coalesce((select (data->'features'->>feature)::boolean from public.unichat_settings where id='published'),true)
$$;
create or replace function public.unichat_validate_profile() returns trigger language plpgsql security definer set search_path='' as $$
 begin
 if length(coalesce(new.data->>'name','')) not between 2 and 80 or trim(coalesce(new.data->>'school',''))='' or trim(coalesce(new.data->>'department',''))='' or trim(coalesce(new.data->>'level',''))='' then raise exception 'Complete all required profile fields';end if;
 new.username:=lower(new.username);new.data:=new.data || jsonb_build_object('username',new.username);
 if tg_op='INSERT' then
  if not public.unichat_feature('registration') and not public.unichat_is_owner() then raise exception 'Registration is paused';end if;
  if not public.unichat_is_owner() then new.status:='active';end if;
 else
  if new.id<>old.id then raise exception 'Profile identity cannot change';end if;
  if not public.unichat_is_owner() and new.status<>old.status then raise exception 'Owner access required';end if;
  if new.id=auth.uid() and public.unichat_is_owner() and new.status='suspended' then raise exception 'Owner cannot suspend own account';end if;
 end if;
 return new;end $$;
drop trigger if exists unichat_validate_profile on public.unichat_profiles;
create trigger unichat_validate_profile before insert or update on public.unichat_profiles for each row execute function public.unichat_validate_profile();

create or replace function public.unichat_guard_content() returns trigger language plpgsql security definer set search_path='' as $$
 declare profile jsonb;target text;
 begin
 if tg_op='UPDATE' and (new.owner<>old.owner or new.kind<>old.kind or new.id<>old.id) then raise exception 'Record identity cannot change';end if;
 select data into profile from public.unichat_profiles where id=new.owner;
 if new.kind='post' then
  if not public.unichat_feature('posting') and not public.unichat_is_owner() then raise exception 'Posting is paused';end if;
  if length(coalesce(new.data->>'text',''))>5000 or (trim(coalesce(new.data->>'text',''))='' and coalesce(new.data->>'media_path','')='') then raise exception 'Write a post or add an attachment';end if;
  new.data:=(new.data - 'media' - 'tag') || jsonb_build_object('id',new.id,'name',profile->>'name','school',profile->>'school','author_id',new.owner,'initial',upper(left(profile->>'name',1)),'likes',0,'comments',0,'time',to_char(new.created_at,'DD Mon YYYY'));
 elsif new.kind in ('like','comment') then
  target:=new.data->>'postId';
  if not exists(select 1 from public.unichat_content where id=target and kind='post') then raise exception 'Post not found';end if;
  if new.kind='like' and new.id<>'like:'||target||':'||new.owner::text then raise exception 'Invalid reaction';end if;
  if new.kind='comment' then
   if length(trim(coalesce(new.data->>'text',''))) not between 1 and 2000 then raise exception 'Reply must contain 1 to 2000 characters';end if;
   new.data:=new.data || jsonb_build_object('name',profile->>'name');
  end if;
 elsif new.kind='message' then
  if not public.unichat_feature('messaging') then raise exception 'Messaging is paused';end if;
  if length(trim(coalesce(new.data->>'text',''))) not between 1 and 4000 then raise exception 'Message must contain 1 to 4000 characters';end if;
  if not exists(select 1 from public.unichat_profiles where id::text=new.data->>'recipient' and status='active' and id<>new.owner) then raise exception 'Recipient is unavailable';end if;
 end if;return new;end $$;
drop trigger if exists unichat_guard_content on public.unichat_content;
create trigger unichat_guard_content before insert or update on public.unichat_content for each row execute function public.unichat_guard_content();

alter table public.unichat_profiles enable row level security;
alter table public.unichat_content enable row level security;
alter table public.unichat_settings enable row level security;
alter table public.unichat_versions enable row level security;

drop policy if exists unichat_profile_read on public.unichat_profiles;
create policy unichat_profile_read on public.unichat_profiles for select to authenticated using(id=auth.uid() or public.unichat_active());
drop policy if exists unichat_profile_create on public.unichat_profiles;
create policy unichat_profile_create on public.unichat_profiles for insert to authenticated with check(id=auth.uid() and (public.unichat_feature('registration') or public.unichat_is_owner()));
drop policy if exists unichat_profile_edit on public.unichat_profiles;
create policy unichat_profile_edit on public.unichat_profiles for update to authenticated using(public.unichat_is_owner() or (id=auth.uid() and status='active')) with check(public.unichat_is_owner() or (id=auth.uid() and status='active'));

drop policy if exists unichat_content_read on public.unichat_content;
create policy unichat_content_read on public.unichat_content for select to authenticated using(public.unichat_active() and (
 kind in ('post','like','comment') or (kind='state' and owner=auth.uid()) or (kind='report' and public.unichat_is_owner()) or (kind='message' and (owner=auth.uid() or data->>'recipient'=auth.uid()::text))));
drop policy if exists unichat_content_create on public.unichat_content;
create policy unichat_content_create on public.unichat_content for insert to authenticated with check(public.unichat_active() and owner=auth.uid() and (kind<>'post' or public.unichat_feature('posting') or public.unichat_is_owner()) and (kind<>'message' or public.unichat_feature('messaging')));
drop policy if exists unichat_content_edit on public.unichat_content;
create policy unichat_content_edit on public.unichat_content for update to authenticated using(public.unichat_active() and ((owner=auth.uid() and kind in ('state','post')) or (public.unichat_is_owner() and kind='post'))) with check(public.unichat_active() and ((owner=auth.uid() and kind in ('state','post')) or (public.unichat_is_owner() and kind='post')));
drop policy if exists unichat_content_remove on public.unichat_content;
create policy unichat_content_remove on public.unichat_content for delete to authenticated using(public.unichat_active() and ((owner=auth.uid() and kind in ('post','like','comment')) or (public.unichat_is_owner() and kind in ('post','comment','report'))));

drop policy if exists unichat_settings_read on public.unichat_settings;
create policy unichat_settings_read on public.unichat_settings for select to anon,authenticated using(id='published' or public.unichat_is_owner());
drop policy if exists unichat_settings_create on public.unichat_settings;
create policy unichat_settings_create on public.unichat_settings for insert to authenticated with check(public.unichat_is_owner());
drop policy if exists unichat_settings_edit on public.unichat_settings;
create policy unichat_settings_edit on public.unichat_settings for update to authenticated using(public.unichat_is_owner()) with check(public.unichat_is_owner());
drop policy if exists unichat_versions_read on public.unichat_versions;
create policy unichat_versions_read on public.unichat_versions for select to authenticated using(public.unichat_is_owner());

create or replace function public.unichat_publish_settings(payload jsonb) returns void language plpgsql security definer set search_path='' as $$
 begin
 if not public.unichat_is_owner() then raise exception 'Owner access required';end if;
 insert into public.unichat_settings(id,data) values('published',payload) on conflict(id) do update set data=excluded.data;
 insert into public.unichat_versions(data) values(payload);
 end $$;
revoke all on function public.unichat_publish_settings(jsonb) from public,anon;
grant execute on function public.unichat_publish_settings(jsonb) to authenticated;
revoke all on function public.unichat_guard_content(),public.unichat_validate_profile() from public,anon,authenticated;
grant select,insert,update on public.unichat_profiles to authenticated;
grant select,insert,update,delete on public.unichat_content to authenticated;
grant select on public.unichat_settings to anon;
grant select,insert,update on public.unichat_settings to authenticated;
grant select on public.unichat_versions to authenticated;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values
 ('unichat-branding','unichat-branding',true,716800,array['image/png','image/jpeg','image/webp']),
 ('unichat-media','unichat-media',false,2621440,array['image/png','image/jpeg','image/webp','image/gif','video/mp4'])
on conflict(id) do nothing;
drop policy if exists unichat_branding_upload on storage.objects;
create policy unichat_branding_upload on storage.objects for insert to authenticated with check(bucket_id='unichat-branding' and public.unichat_is_owner());
drop policy if exists unichat_branding_read on storage.objects;
create policy unichat_branding_read on storage.objects for select to anon,authenticated using(bucket_id='unichat-branding');
drop policy if exists unichat_media_upload on storage.objects;
create policy unichat_media_upload on storage.objects for insert to authenticated with check(bucket_id='unichat-media' and public.unichat_active() and public.unichat_feature('uploads') and (storage.foldername(name))[1]=auth.uid()::text);
drop policy if exists unichat_media_read on storage.objects;
create policy unichat_media_read on storage.objects for select to authenticated using(bucket_id='unichat-media' and public.unichat_active());
-- Realtime streams respect the SELECT policies above.
do $$begin
 if not exists(select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='unichat_content') then
  alter publication supabase_realtime add table public.unichat_content;
 end if;
end$$;
commit;
