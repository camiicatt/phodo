-- phodo — you can change who sees your own post after it's up
-- (friends / everyone / just me). Only your own posts, and the row must stay yours.
drop policy if exists "posts own update" on public.posts;
create policy "posts own update" on public.posts for update to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
