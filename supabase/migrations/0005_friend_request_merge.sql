-- phodo — two people adding each other at the same time should just make them friends.
-- Before: A→B and B→A both existed; accepting one left the other "pending" forever.

-- 1. Clean up existing duplicates.
--    a) both still pending: accept the older request (the newer one is removed in b)
update public.friendships f
set status = 'accepted'
where f.status = 'pending'
  and exists (
    select 1 from public.friendships g
    where g.requester = f.addressee and g.addressee = f.requester
      and g.status = 'pending' and g.created_at > f.created_at
  );
--    b) a pending request whose reverse is already accepted is redundant
delete from public.friendships f
where f.status = 'pending'
  and exists (
    select 1 from public.friendships g
    where g.requester = f.addressee and g.addressee = f.requester and g.status = 'accepted'
  );

-- 2. From now on: asking someone who already asked you = instant friends, one row.
create or replace function public.friend_request_merge()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if exists (select 1 from friendships where requester = new.addressee and addressee = new.requester) then
    update friendships set status = 'accepted'
    where requester = new.addressee and addressee = new.requester;
    return null;   -- don't create a second, mirror-image row
  end if;
  return new;
end;
$$;

drop trigger if exists friend_request_merge on public.friendships;
create trigger friend_request_merge
  before insert on public.friendships
  for each row execute function public.friend_request_merge();
