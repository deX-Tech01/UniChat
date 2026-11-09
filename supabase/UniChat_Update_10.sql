-- Inline comments/replies/reactions and improved one-to-one conversation state.
begin;
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
commit;
