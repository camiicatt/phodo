-- phodo — initial schema (not yet applied; run with `supabase db push` once the
-- Supabase project exists). Privacy lives here, in row-level security.

-- ───────────────────────── profiles ─────────────────────────
create table public.profiles (
  id            uuid primary key references auth.users on delete cascade,
  username      text unique not null check (username ~ '^[a-z0-9_.]{2,24}$'),
  display_name  text not null default '',
  bio           text not null default '' check (char_length(bio) <= 160),
  location      text not null default '',
  theme         text not null default 'lavender',
  is_private    boolean not null default false,
  created_at    timestamptz not null default now()
);

-- ───────────────────────── friendships ─────────────────────────
-- One row per request. status: pending → accepted (declines are deleted).
create table public.friendships (
  requester   uuid not null references public.profiles on delete cascade,
  addressee   uuid not null references public.profiles on delete cascade,
  status      text not null default 'pending' check (status in ('pending', 'accepted')),
  created_at  timestamptz not null default now(),
  primary key (requester, addressee),
  check (requester <> addressee)
);

create or replace function public.are_friends(a uuid, b uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from friendships
    where status = 'accepted'
      and ((requester = a and addressee = b) or (requester = b and addressee = a))
  );
$$;

-- ───────────────────────── posts ─────────────────────────
create table public.posts (
  id          uuid primary key,                         -- generated on the phone
  user_id     uuid not null default auth.uid() references public.profiles on delete cascade,
  local_date  date not null,                            -- the poster's "today"
  caption     text not null default '' check (char_length(caption) <= 500),
  tags        text[] not null default '{}',
  image_path  text,                                     -- {user_id}/{post_id}/full.jpg
  thumb_path  text,                                     -- {user_id}/{post_id}/thumb.jpg
  width       int,
  height      int,
  tint        text,                                     -- average color, hex
  visibility  text not null default 'friends' check (visibility in ('friends', 'private')),
  created_at  timestamptz not null default now(),
  unique (user_id, local_date),                         -- ONE POST PER DAY
  check (image_path is not null or caption <> '')
);
create index posts_feed_idx on public.posts (local_date, user_id);
create index posts_tags_idx on public.posts using gin (tags);

-- ───────────────────────── reactions & comments ─────────────────────────
create table public.reactions (
  post_id     uuid not null references public.posts on delete cascade,
  user_id     uuid not null default auth.uid() references public.profiles on delete cascade,
  emoji       text not null check (emoji in ('🫶', '😂', '🥹', '🔥', '👀')),
  created_at  timestamptz not null default now(),
  primary key (post_id, user_id)
);

create table public.comments (
  id          uuid primary key default gen_random_uuid(),
  post_id     uuid not null references public.posts on delete cascade,
  user_id     uuid not null default auth.uid() references public.profiles on delete cascade,
  body        text not null check (char_length(body) between 1 and 280),
  created_at  timestamptz not null default now()
);

-- ───────────────────────── boards ─────────────────────────
create table public.boards (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null default auth.uid() references public.profiles on delete cascade,
  name        text not null,
  created_at  timestamptz not null default now()
);

create table public.board_items (
  board_id    uuid not null references public.boards on delete cascade,
  post_id     uuid not null references public.posts on delete cascade,
  added_at    timestamptz not null default now(),
  primary key (board_id, post_id)
);

-- ───────────────────────── safety (App Store guideline 1.2) ─────────────────────────
create table public.blocks (
  blocker   uuid not null default auth.uid() references public.profiles on delete cascade,
  blocked   uuid not null references public.profiles on delete cascade,
  primary key (blocker, blocked)
);

create table public.reports (
  id          uuid primary key default gen_random_uuid(),
  reporter    uuid not null default auth.uid() references public.profiles on delete cascade,
  post_id     uuid references public.posts on delete set null,
  user_id     uuid references public.profiles on delete set null,
  reason      text not null,
  created_at  timestamptz not null default now()
);

-- ───────────────────────── row-level security ─────────────────────────
alter table public.profiles    enable row level security;
alter table public.friendships enable row level security;
alter table public.posts       enable row level security;
alter table public.reactions   enable row level security;
alter table public.comments    enable row level security;
alter table public.boards      enable row level security;
alter table public.board_items enable row level security;
alter table public.blocks      enable row level security;
alter table public.reports     enable row level security;

-- profiles: anyone signed in can find people by username; you edit only yours
create policy "profiles readable" on public.profiles for select to authenticated using (true);
create policy "profiles own insert" on public.profiles for insert to authenticated with check (id = auth.uid());
create policy "profiles own update" on public.profiles for update to authenticated using (id = auth.uid());

-- friendships: you see/act on rows you're part of
create policy "friendships mine" on public.friendships for select to authenticated
  using (auth.uid() in (requester, addressee));
create policy "friendships request" on public.friendships for insert to authenticated
  with check (requester = auth.uid() and status = 'pending');
create policy "friendships accept" on public.friendships for update to authenticated
  using (addressee = auth.uid()) with check (status = 'accepted');
create policy "friendships remove" on public.friendships for delete to authenticated
  using (auth.uid() in (requester, addressee));

-- posts: yours always; friends' if visibility = friends and nobody blocked anybody
create policy "posts visible" on public.posts for select to authenticated using (
  user_id = auth.uid()
  or (
    visibility = 'friends'
    and public.are_friends(auth.uid(), user_id)
    and not exists (select 1 from public.blocks b
                    where (b.blocker = auth.uid() and b.blocked = user_id)
                       or (b.blocker = user_id and b.blocked = auth.uid()))
  )
);
create policy "posts own insert" on public.posts for insert to authenticated with check (user_id = auth.uid());
-- edit caption/tags only on today's post (the app sends local_date; server allows ±1 day for time zones)
create policy "posts own update" on public.posts for update to authenticated
  using (user_id = auth.uid() and local_date >= current_date - 1);
create policy "posts own delete" on public.posts for delete to authenticated using (user_id = auth.uid());

-- reactions/comments: you can add on posts you can see; reactions are visible
-- only to the reactor and the poster (no public counts)
create policy "reactions add" on public.reactions for insert to authenticated
  with check (user_id = auth.uid() and exists (select 1 from public.posts p where p.id = post_id));
create policy "reactions see" on public.reactions for select to authenticated using (
  user_id = auth.uid() or exists (select 1 from public.posts p where p.id = post_id and p.user_id = auth.uid())
);
create policy "reactions remove" on public.reactions for delete to authenticated using (user_id = auth.uid());

create policy "comments add" on public.comments for insert to authenticated
  with check (user_id = auth.uid() and exists (select 1 from public.posts p where p.id = post_id));
create policy "comments see" on public.comments for select to authenticated using (
  exists (select 1 from public.posts p where p.id = post_id)
);
create policy "comments remove" on public.comments for delete to authenticated using (
  user_id = auth.uid() or exists (select 1 from public.posts p where p.id = post_id and p.user_id = auth.uid())
);

-- boards: private to their owner
create policy "boards own" on public.boards for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "board items own" on public.board_items for all to authenticated
  using (exists (select 1 from public.boards b where b.id = board_id and b.user_id = auth.uid()))
  with check (exists (select 1 from public.boards b where b.id = board_id and b.user_id = auth.uid()));

create policy "blocks own" on public.blocks for all to authenticated
  using (blocker = auth.uid()) with check (blocker = auth.uid());
create policy "reports create" on public.reports for insert to authenticated with check (reporter = auth.uid());

-- ───────────────────────── photo storage ─────────────────────────
insert into storage.buckets (id, name, public) values ('posts', 'posts', false)
on conflict (id) do nothing;

-- upload only into your own folder: posts/{your user id}/...
create policy "photos upload own" on storage.objects for insert to authenticated
  with check (bucket_id = 'posts' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "photos delete own" on storage.objects for delete to authenticated
  using (bucket_id = 'posts' and (storage.foldername(name))[1] = auth.uid()::text);

-- read a photo only if you can read its post. The subquery runs under the posts
-- policies above, so "can see the post" = "can see the photo".
create policy "photos read if post visible" on storage.objects for select to authenticated using (
  bucket_id = 'posts'
  and (
    (storage.foldername(name))[1] = auth.uid()::text
    or exists (select 1 from public.posts p where name in (p.image_path, p.thumb_path))
  )
);
