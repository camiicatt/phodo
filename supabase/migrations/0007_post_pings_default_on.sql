-- phodo — friends' "posted" pings are ON by default.
-- Instead of opting in per friend (post_alerts), you opt OUT from their profile.
-- post_alerts stays for now so older builds still load; nothing reads it anymore.

create table if not exists public.post_mutes (
  user_id     uuid not null default auth.uid() references public.profiles on delete cascade,
  friend_id   uuid not null references public.profiles on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (user_id, friend_id),
  check (user_id <> friend_id)
);
alter table public.post_mutes enable row level security;
create policy "mutes own" on public.post_mutes for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
