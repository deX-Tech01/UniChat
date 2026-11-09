-- Student matching, collaboration profiles, academic hubs and opportunity preferences.
begin;
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
commit;
