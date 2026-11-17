-- phodo — "at least one a day" (multiple posts + backfilling missed days),
-- an "everyone" visibility for explore, blocking everywhere, and profile pictures.

-- ───────── multiple posts per day ─────────
alter table public.posts drop constraint if exists posts_user_id_local_date_key;
create index if not exists posts_user_date_idx on public.posts (user_id, local_date desc);

-- you can post for today or any missed day, never the future
-- (+1 day of slack because "today" depends on the poster's time zone)
drop policy if exists "posts own insert" on public.posts;
create policy "posts own insert" on public.posts for insert to authenticated
  with check (user_id = auth.uid() and local_date <= current_date + 1);

-- ───────── "everyone" visibility (explore) ─────────
alter table public.posts drop constraint if exists posts_visibility_check;
alter table public.posts add constraint posts_visibility_check
  check (visibility in ('public', 'friends', 'private'));
create index if not exists posts_public_recent_idx on public.posts (created_at desc) where visibility = 'public';

-- does either person block the other?
create or replace function public.is_blocked(a uuid, b uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from blocks
    where (blocker = a and blocked = b) or (blocker = b and blocked = a)
  );
$$;

-- who can see a post:
--   your own: always
--   "everyone": any signed-in person, unless one of you blocked the other
--   "friends": accepted friends, unless blocked
--   "private" ("just me"): only you
drop policy if exists "posts visible" on public.posts;
create policy "posts visible" on public.posts for select to authenticated using (
  user_id = auth.uid()
  or (
    not public.is_blocked(auth.uid(), user_id)
    and (
      visibility = 'public'
      or (visibility = 'friends' and public.are_friends(auth.uid(), user_id))
    )
  )
);
-- (photo storage access follows automatically: it checks this same policy)

-- blocking someone also ends the friendship
create or replace function public.unfriend_on_block()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  delete from friendships
  where (requester = new.blocker and addressee = new.blocked)
     or (requester = new.blocked and addressee = new.blocker);
  return new;
end;
$$;
drop trigger if exists unfriend_on_block on public.blocks;
create trigger unfriend_on_block after insert on public.blocks
  for each row execute function public.unfriend_on_block();

-- ───────── profile pictures ─────────
alter table public.profiles add column if not exists avatar_path text;

insert into storage.buckets (id, name, public) values ('avatars', 'avatars', false)
on conflict (id) do nothing;

-- upload / replace / delete only inside your own folder: avatars/{your id}/...
create policy "avatars upload own" on storage.objects for insert to authenticated
  with check (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
create policy "avatars delete own" on storage.objects for delete to authenticated
  using (bucket_id = 'avatars' and (storage.foldername(name))[1] = auth.uid()::text);
-- any signed-in person can see profile pictures (so friend search shows faces)
create policy "avatars read" on storage.objects for select to authenticated
  using (bucket_id = 'avatars');
