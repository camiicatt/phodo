-- phodo — accounts: 13+ flag and in-app account deletion (App Store 5.1.1(v)).

-- We keep only whether someone confirmed they're 13+, never the birthday.
alter table public.profiles add column if not exists is_13_plus boolean not null default false;

-- New profiles must have passed the age check.
drop policy if exists "profiles own insert" on public.profiles;
create policy "profiles own insert" on public.profiles for insert to authenticated
  with check (id = auth.uid() and is_13_plus);

-- Deletes the calling user. Their profile, posts, friendships, reactions,
-- comments and boards all go with it (ON DELETE CASCADE). The app removes the
-- user's photos from storage first, because storage files can't be deleted from SQL.
create or replace function public.delete_my_account()
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'not signed in';
  end if;
  delete from auth.users where id = auth.uid();
end;
$$;

revoke all on function public.delete_my_account() from public, anon;
grant execute on function public.delete_my_account() to authenticated;
