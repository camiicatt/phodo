-- phodo — likes (♥), public boards, and profile totals (likes + saves + friends).

-- ───────── likes ─────────
create table if not exists public.likes (
  post_id     uuid not null references public.posts on delete cascade,
  user_id     uuid not null default auth.uid() references public.profiles on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (post_id, user_id)
);
create index if not exists likes_user_idx on public.likes (user_id);
alter table public.likes enable row level security;

-- you can like posts you can see (the subquery runs under the posts privacy rules)
create policy "likes add" on public.likes for insert to authenticated
  with check (user_id = auth.uid() and exists (select 1 from public.posts p where p.id = post_id));
-- you see your own likes, and who liked YOUR posts. Nobody else sees per-post likes.
create policy "likes see" on public.likes for select to authenticated using (
  user_id = auth.uid()
  or exists (select 1 from public.posts p where p.id = post_id and p.user_id = auth.uid())
);
create policy "likes remove" on public.likes for delete to authenticated using (user_id = auth.uid());

-- ───────── public boards ─────────
alter table public.boards add column if not exists is_public boolean not null default false;

drop policy if exists "boards own" on public.boards;
create policy "boards see" on public.boards for select to authenticated using (
  user_id = auth.uid() or (is_public and not public.is_blocked(auth.uid(), user_id))
);
create policy "boards own insert" on public.boards for insert to authenticated with check (user_id = auth.uid());
create policy "boards own update" on public.boards for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy "boards own delete" on public.boards for delete to authenticated using (user_id = auth.uid());

drop policy if exists "board items own" on public.board_items;
-- readable when the board is readable (yours, or public). The posts inside still
-- follow the posts privacy rules, so a public board never leaks a friends-only post.
create policy "board items see" on public.board_items for select to authenticated using (
  exists (select 1 from public.boards b where b.id = board_id)
);
create policy "board items own add" on public.board_items for insert to authenticated with check (
  exists (select 1 from public.boards b where b.id = board_id and b.user_id = auth.uid())
);
create policy "board items own remove" on public.board_items for delete to authenticated using (
  exists (select 1 from public.boards b where b.id = board_id and b.user_id = auth.uid())
);

-- ───────── profile totals ─────────
-- Counts only, never who. Saves/likes from the person themself don't count.
create or replace function public.profile_stats(target uuid)
returns table (likes int, saves int, friends int)
language sql stable security definer set search_path = public as $$
  select
    (select count(*) from likes l join posts p on p.id = l.post_id
       where p.user_id = target and l.user_id <> target)::int,
    (select count(*) from board_items bi
       join boards b on b.id = bi.board_id
       join posts p on p.id = bi.post_id
       where p.user_id = target and b.user_id <> target)::int,
    (select count(*) from friendships f
       where f.status = 'accepted' and target in (f.requester, f.addressee))::int;
$$;
revoke all on function public.profile_stats(uuid) from public, anon;
grant execute on function public.profile_stats(uuid) to authenticated;
