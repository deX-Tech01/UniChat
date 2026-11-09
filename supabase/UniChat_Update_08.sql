-- Private birthdays, user preferences, profile/post audiences and follow approval.
begin;
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
commit;
