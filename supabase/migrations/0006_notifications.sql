-- phodo — push notifications: device tokens, per-friend bells, request alerts setting.
-- Pushes are sent by the `notify` edge function (supabase/functions/notify).

-- where to send pushes (one row per phone; a person can have several)
create table if not exists public.push_tokens (
  token       text primary key,
  user_id     uuid not null default auth.uid() references public.profiles on delete cascade,
  sandbox     boolean not null default false,   -- dev builds (Xcode) use Apple's sandbox
  updated_at  timestamptz not null default now()
);
alter table public.push_tokens enable row level security;
create policy "tokens own" on public.push_tokens for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- 🔔 "tell me when @friend posts"
create table if not exists public.post_alerts (
  user_id     uuid not null default auth.uid() references public.profiles on delete cascade,
  friend_id   uuid not null references public.profiles on delete cascade,
  created_at  timestamptz not null default now(),
  primary key (user_id, friend_id),
  check (user_id <> friend_id)
);
alter table public.post_alerts enable row level security;
create policy "alerts own" on public.post_alerts for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- friend request / accepted alerts (on by default)
alter table public.profiles add column if not exists notify_requests boolean not null default true;
