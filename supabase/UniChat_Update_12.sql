-- Direct messages, privacy-aware active status and INSERT ... RETURNING post fix.
begin;
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
