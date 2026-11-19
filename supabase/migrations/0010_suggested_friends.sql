-- phodo — "people you may know": friends of your friends, most mutual friends first.
-- Leaves out you, anyone you already have a request/friendship with, and blocked people.
create or replace function public.suggested_friends()
returns table (id uuid, username text, display_name text, avatar_path text, mutual int)
language sql stable security definer set search_path = public as $$
  with mine as (
    select case when f.requester = auth.uid() then f.addressee else f.requester end as friend
    from friendships f
    where f.status = 'accepted' and auth.uid() in (f.requester, f.addressee)
  ),
  theirs as (
    select case when f.requester = m.friend then f.addressee else f.requester end as person
    from friendships f join mine m on m.friend in (f.requester, f.addressee)
    where f.status = 'accepted'
  )
  select p.id, p.username, p.display_name, p.avatar_path, count(*)::int as mutual
  from theirs t join profiles p on p.id = t.person
  where t.person <> auth.uid()
    and not exists (
      select 1 from friendships x
      where (x.requester = auth.uid() and x.addressee = t.person)
         or (x.addressee = auth.uid() and x.requester = t.person))
    and not public.is_blocked(auth.uid(), t.person)
  group by p.id, p.username, p.display_name, p.avatar_path
  order by mutual desc, p.username
  limit 15;
$$;
revoke all on function public.suggested_friends() from public, anon;
grant execute on function public.suggested_friends() to authenticated;
