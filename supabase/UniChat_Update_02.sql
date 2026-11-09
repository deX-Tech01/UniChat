-- UniChat update 02: communities, events, message requests and blocking.
-- Apply AFTER UniChat_Setup.sql. Existing profiles, posts and branding stay intact.
begin;
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
commit;
