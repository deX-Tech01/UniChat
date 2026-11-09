-- Self-service lifecycle and privacy-aware administrative tools.
begin;
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
commit;
