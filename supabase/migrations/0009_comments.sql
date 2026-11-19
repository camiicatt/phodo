-- phodo — tiny comments ("so cute", "awww", "love this").
-- 30 characters, and a kindness filter that stops cuss words, slurs and "kys"-type stuff.
-- The filter mirrors phodo/Services/CommentRules.swift. Keep the two in sync.

create table if not exists public.comments (
  id          uuid primary key default gen_random_uuid(),
  post_id     uuid not null references public.posts on delete cascade,
  user_id     uuid not null default auth.uid() references public.profiles on delete cascade,
  -- 30 on the phone (counted as characters you see); a little slack here for
  -- emoji that are several code points (flags, skin tones)
  body        text not null check (char_length(btrim(body)) between 1 and 40),
  created_at  timestamptz not null default now()
);
create index if not exists comments_post_idx on public.comments (post_id, created_at);
create index if not exists comments_user_idx on public.comments (user_id, created_at);
alter table public.comments enable row level security;

-- ───────── the kindness filter ─────────
create or replace function public.comment_flagged(body text)
returns boolean language plpgsql immutable set search_path = public as $$
declare
  s text := translate(lower(body), '0134578@$!|+', 'oieastbasiit');
  squashed text := regexp_replace(s, '[^a-z]', '', 'g');
  word text;
begin
  -- whole comment, spaces/symbols removed (long, distinctive patterns only)
  if squashed ~ '(n+i+g{2,}|f+a+g+o+t|t+r+a+n{2,}y|k+i+l+(y+o+u+r*|u+r*)s+e+l+f|m+o+t+h+e+r+f|c+u+n+t)' then
    return true;
  end if;
  -- each word on its own, plus the whole thing squashed ("k y s", "w t f")
  foreach word in array regexp_split_to_array(s, '[^a-z]+') || squashed loop
    if word ~ ('^('
      || 'f+u*c+k+.*|f+u+k+.*|f+c+u+k+.*|p+h+u+c*k+.*'
      || '|s+h+i+t+.*|b+i+t+c+h+.*|b+a+s+t+a+r+d+.*'
      || '|w+h+o+r+e+s*|s+l+u+t+.*'
      || '|a+s+s+(h+o+l+e+s*|e+s)?|a+r+s+e+|(j+a+c+k+|d+u+m+b+|s+m+a+r+t+)a+s+s+'
      || '|d+i+c+k+(h+e+a+d+)?s*|c+o+c+k+s*|p+u+s+s+y+'
      || '|p+i+s+s+(e+d+|i+n+g*)?'
      || '|w+t+f+|s+t+f+u+|k+y+s+'
      || '|f+a+g+s*|r+e+t+a+r+d+.*'
      || '|(s+p+i+c+|c+h+i+n+k+|k+i+k+e+|g+o+o+k+|c+o+o+n+|d+y+k+e+|b+e+a+n+e+r+)s*'
      || '|(w+e+t+b+a+c+k+|r+a+g+h+e+a+d+|t+o+w+e+l+h+e+a+d+)s*'
      || ')$') then
      return true;
    end if;
  end loop;
  return false;
end $$;

-- runs on every new comment (and edits, if those ever exist)
create or replace function public.comments_check()
returns trigger language plpgsql set search_path = public as $$
begin
  new.body := btrim(new.body);
  if public.comment_flagged(new.body) then
    raise exception 'not_nice' using errcode = 'P0001';
  end if;
  -- no flooding: 10 a minute is plenty for "awww"
  if (select count(*) from public.comments c
        where c.user_id = new.user_id and c.created_at > now() - interval '1 minute') >= 10 then
    raise exception 'slow_down' using errcode = 'P0001';
  end if;
  return new;
end $$;

drop trigger if exists comments_check on public.comments;
create trigger comments_check before insert or update of body on public.comments
  for each row execute function public.comments_check();

-- ───────── who can do what ─────────
-- see: comments on posts you can see (the subquery runs under the posts privacy
-- rules), minus anyone you've blocked or who blocked you
drop policy if exists "comments see" on public.comments;
create policy "comments see" on public.comments for select to authenticated using (
  exists (select 1 from public.posts p where p.id = post_id)
  and not public.is_blocked(auth.uid(), user_id)
);
-- add: as yourself, on a post you can see
drop policy if exists "comments add" on public.comments;
create policy "comments add" on public.comments for insert to authenticated with check (
  user_id = auth.uid()
  and exists (select 1 from public.posts p where p.id = post_id)
);
-- delete: your own, or anything on your post
drop policy if exists "comments remove" on public.comments;
create policy "comments remove" on public.comments for delete to authenticated using (
  user_id = auth.uid()
  or exists (select 1 from public.posts p where p.id = post_id and p.user_id = auth.uid())
);
