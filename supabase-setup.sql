-- مينا امغاد: إعداد قاعدة البيانات. الصق هذا كله في Supabase > SQL Editor ثم اضغط Run.

create table if not exists public.profiles (
  user_id uuid primary key references auth.users(id) on delete cascade,
  serial text unique not null,
  name text not null default '',
  created_at timestamptz not null default now()
);
alter table public.profiles add column if not exists avatar text not null default '';
alter table public.profiles enable row level security;
drop policy if exists "profiles_select_own" on public.profiles;
drop policy if exists "profiles_insert_own" on public.profiles;
drop policy if exists "profiles_update_own" on public.profiles;
create policy "profiles_select_own" on public.profiles for select using (user_id = auth.uid());
create policy "profiles_insert_own" on public.profiles for insert with check (user_id = auth.uid());
create policy "profiles_update_own" on public.profiles for update using (user_id = auth.uid()) with check (user_id = auth.uid());

create table if not exists public.contacts (
  owner uuid not null references auth.users(id) on delete cascade,
  friend uuid not null references auth.users(id) on delete cascade,
  primary key (owner, friend)
);
alter table public.contacts enable row level security;
drop policy if exists "contacts_own" on public.contacts;
create policy "contacts_own" on public.contacts for all using (owner = auth.uid()) with check (owner = auth.uid());

create table if not exists public.messages (
  id bigint generated always as identity primary key,
  sender uuid not null default auth.uid() references auth.users(id) on delete cascade,
  receiver uuid not null references auth.users(id) on delete cascade,
  body text not null check (char_length(body) between 1 and 2000),
  created_at timestamptz not null default now()
);
create index if not exists messages_receiver_idx on public.messages (receiver, created_at);
create index if not exists messages_sender_idx on public.messages (sender, created_at);
alter table public.messages enable row level security;
drop policy if exists "messages_select_mine" on public.messages;
drop policy if exists "messages_insert_as_me" on public.messages;
create policy "messages_select_mine" on public.messages for select using (sender = auth.uid() or receiver = auth.uid());
create policy "messages_insert_as_me" on public.messages for insert with check (sender = auth.uid());

-- تفعيل الاستقبال الفوري للرسائل
do $$ begin
  alter publication supabase_realtime add table public.messages;
exception when duplicate_object then null; end $$;

-- حذف الدوال القديمة ثم إنشاؤها (لأن الأعمدة المُرجعة تغيّرت)
drop function if exists public.find_profile(text);
drop function if exists public.get_profiles(uuid[]);

-- البحث عن شخص برقمه التسلسلي فقط (لا قائمة عامة)
create or replace function public.find_profile(p_serial text)
returns table (user_id uuid, name text, serial text, avatar text)
language sql security definer set search_path = public stable as $$
  select p.user_id, p.name, p.serial, p.avatar from public.profiles p
  where p.serial = upper(trim(p_serial)) limit 1
$$;

-- أسماء وصور من بينك وبينهم جهة اتصال أو رسائل فقط
create or replace function public.get_profiles(p_ids uuid[])
returns table (user_id uuid, name text, serial text, avatar text)
language sql security definer set search_path = public stable as $$
  select p.user_id, p.name, p.serial, p.avatar from public.profiles p
  where p.user_id = any(p_ids) and (
    exists (select 1 from public.contacts c where c.owner = auth.uid() and c.friend = p.user_id)
    or exists (select 1 from public.messages m
               where (m.sender = p.user_id and m.receiver = auth.uid())
                  or (m.receiver = p.user_id and m.sender = auth.uid()))
  )
$$;

revoke all on function public.find_profile(text) from public, anon;
revoke all on function public.get_profiles(uuid[]) from public, anon;
grant execute on function public.find_profile(text) to authenticated;
grant execute on function public.get_profiles(uuid[]) to authenticated;

-- =====================================================================
-- الجزء الثاني: القصص والمجموعات
-- =====================================================================

-- صديقان = كلٌّ منهما أضاف الآخر (بالبحث ثم الدردشة)
create or replace function public.are_friends(a uuid, b uuid)
returns boolean language sql security definer set search_path = public stable as $$
  select a = b or (
    exists (select 1 from public.contacts where owner = a and friend = b)
    and exists (select 1 from public.contacts where owner = b and friend = a))
$$;

create or replace function public.can_read_story_folder(a uuid, folder text)
returns boolean language sql security definer set search_path = public stable as $$
  select case when folder ~ '^[0-9a-fA-F-]{36}$' then public.are_friends(a, folder::uuid) else false end
$$;

-- ---------- القصص ----------
create table if not exists public.stories (
  id bigint generated always as identity primary key,
  author uuid not null default auth.uid() references auth.users(id) on delete cascade,
  caption text not null default '' check (char_length(caption) <= 500),
  media_type text not null default '' check (media_type in ('', 'image', 'video')),
  media_path text not null default '',
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '24 hours')
);
alter table public.stories enable row level security;
drop policy if exists "stories_select" on public.stories;
drop policy if exists "stories_insert" on public.stories;
drop policy if exists "stories_delete" on public.stories;
create policy "stories_select" on public.stories for select using (expires_at > now() and public.are_friends(auth.uid(), author));
create policy "stories_insert" on public.stories for insert with check (author = auth.uid());
create policy "stories_delete" on public.stories for delete using (author = auth.uid());

create table if not exists public.story_views (
  story_id bigint not null references public.stories(id) on delete cascade,
  viewer uuid not null default auth.uid() references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (story_id, viewer)
);
alter table public.story_views enable row level security;
drop policy if exists "views_select" on public.story_views;
drop policy if exists "views_insert" on public.story_views;
create policy "views_select" on public.story_views for select using (
  viewer = auth.uid() or exists (select 1 from public.stories s where s.id = story_id and s.author = auth.uid()));
create policy "views_insert" on public.story_views for insert with check (
  viewer = auth.uid() and exists (select 1 from public.stories s where s.id = story_id and public.are_friends(auth.uid(), s.author)));

create table if not exists public.story_reactions (
  story_id bigint not null references public.stories(id) on delete cascade,
  viewer uuid not null default auth.uid() references auth.users(id) on delete cascade,
  emoji text not null check (char_length(emoji) <= 16),
  primary key (story_id, viewer)
);
alter table public.story_reactions enable row level security;
drop policy if exists "react_select" on public.story_reactions;
drop policy if exists "react_insert" on public.story_reactions;
drop policy if exists "react_update" on public.story_reactions;
create policy "react_select" on public.story_reactions for select using (
  viewer = auth.uid() or exists (select 1 from public.stories s where s.id = story_id and s.author = auth.uid()));
create policy "react_insert" on public.story_reactions for insert with check (
  viewer = auth.uid() and exists (select 1 from public.stories s where s.id = story_id and public.are_friends(auth.uid(), s.author)));
create policy "react_update" on public.story_reactions for update using (viewer = auth.uid()) with check (viewer = auth.uid());

-- مخزن صور وفيديوهات القصص (خاص، والروابط مؤقتة)
insert into storage.buckets (id, name, public, file_size_limit)
values ('stories', 'stories', false, 47185920)
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit;
drop policy if exists "stories_obj_upload" on storage.objects;
drop policy if exists "stories_obj_read" on storage.objects;
drop policy if exists "stories_obj_delete" on storage.objects;
create policy "stories_obj_upload" on storage.objects for insert to authenticated
  with check (bucket_id = 'stories' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "stories_obj_read" on storage.objects for select to authenticated
  using (bucket_id = 'stories' and public.can_read_story_folder(auth.uid(), (storage.foldername(name))[1]));
create policy "stories_obj_delete" on storage.objects for delete to authenticated
  using (bucket_id = 'stories' and (storage.foldername(name))[1] = auth.uid()::text);

-- ---------- المجموعات ----------
create table if not exists public.groups (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(name) between 1 and 60),
  rules text not null default '' check (char_length(rules) <= 1000),
  owner uuid not null default auth.uid() references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
create table if not exists public.group_members (
  group_id uuid not null references public.groups(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null default 'member' check (role in ('owner', 'admin', 'member')),
  joined_at timestamptz not null default now(),
  primary key (group_id, user_id)
);
create table if not exists public.group_messages (
  id bigint generated always as identity primary key,
  group_id uuid not null references public.groups(id) on delete cascade,
  sender uuid not null default auth.uid() references auth.users(id) on delete cascade,
  body text not null check (char_length(body) between 1 and 2000),
  created_at timestamptz not null default now()
);
create index if not exists group_messages_idx on public.group_messages (group_id, created_at);

create or replace function public.is_member(gid uuid) returns boolean
language sql security definer set search_path = public stable as $$
  select exists (select 1 from public.group_members where group_id = gid and user_id = auth.uid()) $$;
create or replace function public.is_group_admin(gid uuid) returns boolean
language sql security definer set search_path = public stable as $$
  select exists (select 1 from public.group_members where group_id = gid and user_id = auth.uid() and role in ('owner', 'admin')) $$;

alter table public.groups enable row level security;
alter table public.group_members enable row level security;
alter table public.group_messages enable row level security;
drop policy if exists "groups_select" on public.groups;
drop policy if exists "groups_update" on public.groups;
drop policy if exists "gm_select" on public.group_members;
drop policy if exists "gm_leave" on public.group_members;
drop policy if exists "gmsg_select" on public.group_messages;
drop policy if exists "gmsg_insert" on public.group_messages;
create policy "groups_select" on public.groups for select using (public.is_member(id));
create policy "groups_update" on public.groups for update using (owner = auth.uid()) with check (owner = auth.uid());
create policy "gm_select" on public.group_members for select using (public.is_member(group_id));
create policy "gm_leave" on public.group_members for delete using (user_id = auth.uid());
create policy "gmsg_select" on public.group_messages for select using (public.is_member(group_id));
create policy "gmsg_insert" on public.group_messages for insert with check (sender = auth.uid() and public.is_member(group_id));

do $$ begin
  alter publication supabase_realtime add table public.group_messages;
exception when duplicate_object then null; end $$;

create or replace function public.create_group(p_name text, p_rules text) returns uuid
language plpgsql security definer set search_path = public as $$
declare gid uuid;
begin
  if auth.uid() is null then raise exception 'not_authenticated'; end if;
  insert into public.groups (name, rules, owner) values (trim(p_name), coalesce(p_rules, ''), auth.uid()) returning id into gid;
  insert into public.group_members (group_id, user_id, role) values (gid, auth.uid(), 'owner');
  return gid;
end $$;

-- إضافة عضو: للمشرفين فقط، وبالرقم التسلسلي، ويُشترط أن يكون صديقاً متبادلاً
create or replace function public.add_group_member(p_group uuid, p_serial text) returns void
language plpgsql security definer set search_path = public as $$
declare uid uuid;
begin
  if not public.is_group_admin(p_group) then raise exception 'not_admin'; end if;
  select user_id into uid from public.profiles where serial = upper(trim(p_serial));
  if uid is null then raise exception 'not_found'; end if;
  if not public.are_friends(auth.uid(), uid) then raise exception 'not_friend'; end if;
  insert into public.group_members (group_id, user_id) values (p_group, uid) on conflict do nothing;
end $$;

create or replace function public.remove_group_member(p_group uuid, p_user uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_group_admin(p_group) then raise exception 'not_admin'; end if;
  delete from public.group_members where group_id = p_group and user_id = p_user and role = 'member';
end $$;

create or replace function public.group_members_info(p_group uuid)
returns table (user_id uuid, name text, avatar text, role text)
language sql security definer set search_path = public stable as $$
  select m.user_id, p.name, p.avatar, m.role
  from public.group_members m join public.profiles p on p.user_id = m.user_id
  where m.group_id = p_group and public.is_member(p_group)
  order by m.joined_at
$$;

revoke all on function public.create_group(text, text) from public, anon;
revoke all on function public.add_group_member(uuid, text) from public, anon;
revoke all on function public.remove_group_member(uuid, uuid) from public, anon;
revoke all on function public.group_members_info(uuid) from public, anon;
grant execute on function public.create_group(text, text) to authenticated;
grant execute on function public.add_group_member(uuid, text) to authenticated;
grant execute on function public.remove_group_member(uuid, uuid) to authenticated;
grant execute on function public.group_members_info(uuid) to authenticated;
