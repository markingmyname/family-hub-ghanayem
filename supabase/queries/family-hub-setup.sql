-- Family Hub — run once per household, in the Supabase SQL editor.
-- Safe to run again: it tidies up after the earlier, looser version.

create table if not exists family_hub_state (
  family_id  text primary key,
  payload    text not null,
  rev        bigint not null default 0,
  updated_by text,
  updated_at timestamptz not null default now()
);

alter table family_hub_state enable row level security;

-- The table is not reachable with a public key. No policies, no privileges:
-- every request has to come through the three functions below, and each of
-- those demands the family id. There is no query that will list ids for you.
drop policy if exists "family hub read"   on family_hub_state;
drop policy if exists "family hub insert" on family_hub_state;
drop policy if exists "family hub update" on family_hub_state;
revoke all on table family_hub_state from anon, authenticated;

-- Poll: the revision marker only, which is what keeps checking cheap.
create or replace function family_hub_meta(fid text)
returns table (rev bigint, updated_at timestamptz, updated_by text)
language sql security definer set search_path = public as $$
  select rev, updated_at, updated_by from family_hub_state where family_id = fid;
$$;

-- Read the family's board.
create or replace function family_hub_get(fid text)
returns table (payload text, rev bigint, updated_at timestamptz, updated_by text)
language sql security definer set search_path = public as $$
  select payload, rev, updated_at, updated_by from family_hub_state where family_id = fid;
$$;

-- Write it back. The database picks the revision, so two devices can't collide.
create or replace function family_hub_put(fid text, body text, newrev bigint, device text)
returns bigint
language plpgsql security definer set search_path = public as $$
declare stored bigint;
begin
  if fid is null or length(fid) < 12 then
    raise exception 'family id is too short to be safe';
  end if;
  -- Once a family signs in with Google, its members are tied to this row, so a
  -- device still on the old family code must not move the board to a new code.
  if body like '{"__movedTo"%' and exists (select 1 from family_hub_members m where m.family_id = fid) then
    raise exception 'this family signs in with Google now, so its code cannot be changed';
  end if;
  insert into family_hub_state as t (family_id, payload, rev, updated_by, updated_at)
  values (fid, body, coalesce(newrev, 1), device, now())
  on conflict (family_id) do update
    set payload    = excluded.payload,
        rev        = greatest(t.rev + 1, excluded.rev),
        updated_by = excluded.updated_by,
        updated_at = now()
  returning t.rev into stored;
  return stored;
end;
$$;

revoke all on function family_hub_meta(text) from public;
revoke all on function family_hub_get(text) from public;
revoke all on function family_hub_put(text, text, bigint, text) from public;
grant execute on function family_hub_meta(text) to anon, authenticated;
grant execute on function family_hub_get(text) to anon, authenticated;
grant execute on function family_hub_put(text, text, bigint, text) to anon, authenticated;

-- Apple Reminders bridge. A Shortcut on a phone can post one item at a time
-- without being handed the whole board: this adds, and only adds. It cannot
-- read anything back, cannot edit and cannot delete, and it quietly ignores
-- anything already on the list, so a Shortcut is safe to run on a schedule.
drop function if exists family_hub_add(text, text, text, text, text, text);
create or replace function family_hub_add(
  fid       text,
  kind      text,
  item_name text,
  list_name text default null,
  note      text default '',
  due       text default '',
  assign_to text default ''
)
returns text
language plpgsql security definer set search_path = public as $$
declare
  doc     jsonb;
  arr     jsonb;
  clean   text;
  lname   text;
  who     text;
  duedate text;
  newid   text;
  lid     text;
  pids    jsonb;
begin
  if fid is null or length(fid) < 12 then
    raise exception 'family id is too short to be safe';
  end if;
  if kind is null or kind not in ('grocery','todo') then
    raise exception 'kind must be grocery or todo';
  end if;

  clean := left(btrim(coalesce(item_name, '')), 200);
  if clean = '' then return 'skipped'; end if;

  select payload::jsonb into doc from family_hub_state where family_id = fid for update;
  if doc is null then return 'no-family'; end if;

  newid := substr(md5(random()::text || clock_timestamp()::text), 1, 7);

  if kind = 'grocery' then
    if doc->'meals' is null then doc := jsonb_set(doc, '{meals}', '{}'::jsonb); end if;
    arr := coalesce(doc#>'{meals,grocery}', '[]'::jsonb);

    if exists (
      select 1 from jsonb_array_elements(arr) g
       where lower(btrim(g->>'name')) = lower(clean)
         and coalesce((g->>'done')::boolean, false) = false
    ) then return 'already-there'; end if;

    -- No aisle here on purpose: the app sorts unfiled items when it loads them.
    doc := jsonb_set(doc, '{meals,grocery}', arr || jsonb_build_object(
      'id', newid, 'name', clean, 'qty', '',
      'note', left(btrim(coalesce(note, '')), 300),
      'done', false, 'order', jsonb_array_length(arr)
    ));

  else
    if doc->'todos' is null then
      doc := jsonb_set(doc, '{todos}', '{"lists":[],"sections":[],"items":[]}'::jsonb);
    end if;
    if doc#>'{todos,lists}' is null then doc := jsonb_set(doc, '{todos,lists}', '[]'::jsonb); end if;

    lname := left(btrim(coalesce(list_name, '')), 60);
    if lname = '' then lname := 'Reminders'; end if;

    select l->>'id' into lid
      from jsonb_array_elements(doc#>'{todos,lists}') l
     where lower(btrim(l->>'name')) = lower(lname)
     limit 1;

    if lid is null then
      lid := 'l' || substr(md5(random()::text || clock_timestamp()::text), 1, 6);
      doc := jsonb_set(doc, '{todos,lists}', (doc#>'{todos,lists}') || jsonb_build_object(
        'id', lid, 'name', lname, 'color', '#8A8F98', 'emoji', '📌'
      ));
    end if;

    -- Whoever the list belongs to. A Reminders list rarely carries the same
    -- name as the person on the board (Katie's list, Mom's column), so the
    -- Shortcut can name them outright; the list name is only the fallback.
    who := left(btrim(coalesce(assign_to, '')), 60);
    if who = '' then who := lname; end if;
    select jsonb_agg(p->>'id') into pids
      from jsonb_array_elements(coalesce(doc->'people', '[]'::jsonb)) p
     where lower(btrim(p->>'name')) = lower(who) or p->>'id' = who;

    duedate := left(btrim(coalesce(due, '')), 10);
    if duedate !~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' then duedate := ''; end if;

    arr := coalesce(doc#>'{todos,items}', '[]'::jsonb);
    if exists (
      select 1 from jsonb_array_elements(arr) t
       where lower(btrim(t->>'title')) = lower(clean)
         and coalesce((t->>'done')::boolean, false) = false
         and t->>'listId' = lid
    ) then return 'already-there'; end if;

    doc := jsonb_set(doc, '{todos,items}', arr || jsonb_build_object(
      'id', newid, 'listId', lid, 'sectionId', null, 'title', clean,
      'notes', left(btrim(coalesce(note, '')), 500), 'due', duedate,
      'priority', 0, 'flagged', false, 'personIds', coalesce(pids, '[]'::jsonb),
      'points', 0, 'parentId', null, 'attachments', '[]'::jsonb,
      'done', false, 'awardedTo', null, 'order', jsonb_array_length(arr)
    ));
  end if;

  update family_hub_state
     set payload = doc::text, rev = rev + 1, updated_by = 'reminders', updated_at = now()
   where family_id = fid;
  return 'added';
end;
$$;

revoke all on function family_hub_add(text, text, text, text, text, text, text) from public;
grant execute on function family_hub_add(text, text, text, text, text, text, text) to anon, authenticated;

-- ===== Google sign-in =====
-- Every family member signs in with their own Google account, and only the
-- accounts on the family's list can open its board. Supabase also needs Google
-- turned on: Authentication, then Sign In / Providers, then Google.

-- The family's list: one row per Google email. user_id fills in the first
-- time that person signs in. One family per account, so both are unique.
create table if not exists public.family_hub_members (
  email      text primary key check (email = lower(email) and email ~ '^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$'),
  family_id  text not null references public.family_hub_state(family_id) on delete cascade,
  person_id  text,
  user_id    uuid unique references auth.users(id) on delete set null,
  added_at   timestamptz not null default now()
);
alter table public.family_hub_members enable row level security;
revoke all on table public.family_hub_members from anon, authenticated;

-- Each person's own settings: time format, views, weather, screensaver.
create table if not exists public.family_hub_settings (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  settings   jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);
alter table public.family_hub_settings enable row level security;
revoke all on table public.family_hub_settings from anon, authenticated;

-- Like the board, both tables are reachable only through the functions below.
-- Each works out the caller's family from their sign-in, so there is no
-- family id to pass, guess or leak. search_path is empty and every name is
-- schema-qualified, so a caller cannot slip in an object of their own.

-- Who am I? On first sign-in this claims the invite for the account's email.
-- Only Google sign-ins claim invites; app_metadata is written by Supabase and
-- cannot be edited by the user.
create or replace function public.fh_me()
returns table (family_id text, person_id text, email text)
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_column
declare
  uid  uuid := auth.uid();
  mail text := lower(coalesce(auth.jwt() ->> 'email', ''));
begin
  if uid is null then raise exception 'sign in first' using errcode = '28000'; end if;
  if not exists (select 1 from public.family_hub_members m where m.user_id = uid)
     and coalesce(auth.jwt() -> 'app_metadata' ->> 'provider', '') = 'google' and mail <> '' then
    update public.family_hub_members m set user_id = uid where m.email = mail and m.user_id is null;
  end if;
  return query select m.family_id, m.person_id, m.email from public.family_hub_members m where m.user_id = uid;
end;
$$;

-- First sign-in for a family with no list yet: claim the family this device
-- already syncs with (fid), or start a new one from this device's board
-- (fid null). Once a family has a list, only its members can add people.
create or replace function public.fh_setup(fid text, body text)
returns text
language plpgsql security definer set search_path = '' as $$
#variable_conflict use_column
declare
  uid    uuid := auth.uid();
  mail   text := lower(coalesce(auth.jwt() ->> 'email', ''));
  target text;
begin
  if uid is null or mail = '' or coalesce(auth.jwt() -> 'app_metadata' ->> 'provider', '') <> 'google' then
    raise exception 'sign in with Google first' using errcode = '28000';
  end if;
  if exists (select 1 from public.family_hub_members m where m.user_id = uid or m.email = mail) then
    raise exception 'this Google account is already on a family list' using errcode = '23505';
  end if;
  if fid is not null then
    perform 1 from public.family_hub_state s where s.family_id = fid for update;
    if not found then raise exception 'no family has that code' using errcode = 'P0002'; end if;
    if exists (select 1 from public.family_hub_members m where m.family_id = fid) then
      raise exception 'that family already signs in with Google, so ask someone on it to add your email' using errcode = '42501';
    end if;
    target := fid;
  else
    if body is null or btrim(body) = '' then
      raise exception 'there is no board to start the family with' using errcode = '22023';
    end if;
    target := 'family-' || replace(gen_random_uuid()::text, '-', '');
    insert into public.family_hub_state (family_id, payload, rev, updated_by) values (target, body, 1, 'setup');
  end if;
  insert into public.family_hub_members (email, family_id, user_id) values (mail, target, uid);
  return target;
end;
$$;

-- The board, for whoever is signed in. Same shapes as the family-code
-- functions above, minus the family id.
create or replace function public.fh_meta()
returns table (rev bigint, updated_at timestamptz, updated_by text)
language sql stable security definer set search_path = '' as $$
  select s.rev, s.updated_at, s.updated_by
    from public.family_hub_state s
    join public.family_hub_members m on m.family_id = s.family_id
   where m.user_id = auth.uid();
$$;

create or replace function public.fh_get()
returns table (payload text, rev bigint, updated_at timestamptz, updated_by text)
language sql stable security definer set search_path = '' as $$
  select s.payload, s.rev, s.updated_at, s.updated_by
    from public.family_hub_state s
    join public.family_hub_members m on m.family_id = s.family_id
   where m.user_id = auth.uid();
$$;

create or replace function public.fh_put(body text, newrev bigint, device text)
returns bigint
language plpgsql security definer set search_path = '' as $$
declare
  fid    text;
  stored bigint;
begin
  select m.family_id into fid from public.family_hub_members m where m.user_id = auth.uid();
  if fid is null then raise exception 'not on a family list' using errcode = '42501'; end if;
  update public.family_hub_state t
     set payload = body, rev = greatest(t.rev + 1, coalesce(newrev, 1)), updated_by = device, updated_at = now()
   where t.family_id = fid
  returning t.rev into stored;
  return stored;
end;
$$;

-- The family's list, for its members only.
create or replace function public.fh_members()
returns table (email text, person_id text, signed_in boolean)
language sql stable security definer set search_path = '' as $$
  select m.email, m.person_id, m.user_id is not null
    from public.family_hub_members m
   where m.family_id = (select me.family_id from public.family_hub_members me where me.user_id = auth.uid())
   order by m.added_at, m.email;
$$;

-- Give a person on the board a Google email, or none to take their access
-- away. Your own row can be relinked to another person but never removed,
-- so nobody can lock themselves out.
create or replace function public.fh_set_member(person text, new_email text)
returns void
language plpgsql security definer set search_path = '' as $$
declare
  fid  text;
  mine text;
  mail text := nullif(lower(btrim(coalesce(new_email, ''))), '');
begin
  select m.family_id, m.email into fid, mine from public.family_hub_members m where m.user_id = auth.uid();
  if fid is null then raise exception 'not on a family list' using errcode = '42501'; end if;
  if person is null or btrim(person) = '' then raise exception 'pick a person' using errcode = '22023'; end if;
  if mail is not null and mail !~ '^[^@[:space:]]+@[^@[:space:]]+[.][^@[:space:]]+$' then
    raise exception 'that is not an email address' using errcode = '22023';
  end if;
  delete from public.family_hub_members m
   where m.family_id = fid and m.person_id = person and m.email <> mine and m.email is distinct from mail;
  if mail is null then return; end if;
  if exists (select 1 from public.family_hub_members m where m.email = mail and m.family_id <> fid) then
    raise exception 'that Google account is on another family list' using errcode = '23505';
  end if;
  insert into public.family_hub_members as m (email, family_id, person_id) values (mail, fid, person)
  on conflict (email) do update set person_id = excluded.person_id where m.family_id = excluded.family_id;
end;
$$;

-- Take an account off the list by email, for accounts not linked to anyone
-- on the board. Never your own.
create or replace function public.fh_remove_member(target_email text)
returns void
language plpgsql security definer set search_path = '' as $$
declare
  fid    text;
  mine   text;
  target text := lower(btrim(coalesce(target_email, '')));
begin
  select m.family_id, m.email into fid, mine from public.family_hub_members m where m.user_id = auth.uid();
  if fid is null then raise exception 'not on a family list' using errcode = '42501'; end if;
  if target = mine then raise exception 'you cannot remove yourself' using errcode = '42501'; end if;
  delete from public.family_hub_members m where m.family_id = fid and m.email = target;
end;
$$;

-- Your own settings. Members only, and capped at 64 KB.
create or replace function public.fh_get_settings()
returns jsonb
language sql stable security definer set search_path = '' as $$
  select s.settings from public.family_hub_settings s where s.user_id = auth.uid();
$$;

create or replace function public.fh_put_settings(body jsonb)
returns void
language plpgsql security definer set search_path = '' as $$
begin
  if not exists (select 1 from public.family_hub_members m where m.user_id = auth.uid()) then
    raise exception 'not on a family list' using errcode = '42501';
  end if;
  if body is null or jsonb_typeof(body) <> 'object' or pg_column_size(body) > 65536 then
    raise exception 'settings must be a small JSON object' using errcode = '22023';
  end if;
  insert into public.family_hub_settings as s (user_id, settings, updated_at) values (auth.uid(), body, now())
  on conflict (user_id) do update set settings = excluded.settings, updated_at = now();
end;
$$;

-- The two functions below replace fh_meta/fh_put for devices running the
-- change-tracking build. They are NEW names rather than changes to the old
-- ones so that a phone still showing the previous version of the page keeps
-- working until it is reloaded.

-- Same job as fh_meta, plus the server's own clock. Devices use that clock to
-- stamp their edits, so a tablet whose date is a day out cannot win or lose
-- every disagreement purely because of its clock. Returns NULL when this
-- person is on no family list, or the family has no board yet -- the same two
-- "nothing here" cases fh_meta signalled by returning no rows.
create or replace function public.fh_meta_v2()
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  fid text;
  r   record;
begin
  select m.family_id into fid from public.family_hub_members m where m.user_id = auth.uid();
  if fid is null then return null; end if;
  select s.rev, s.updated_at, s.updated_by into r
    from public.family_hub_state s where s.family_id = fid;
  if not found then return null; end if;
  return jsonb_build_object('rev', r.rev, 'updated_at', r.updated_at,
                            'updated_by', r.updated_by, 'server_now', now());
end;
$$;

-- Writes the board, but only if nobody else has written since the copy this
-- device was holding. The baserev argument is the revision the device last
-- agreed with; if the stored revision has moved on, the write is REFUSED and
-- the device is told so, rather than overwriting work it never saw. It then
-- merges the newer copy with its own and tries again.
--
-- The for-update clause locks the row for the rest of the transaction.
-- Without it two devices could both read the same revision, both pass the
-- check, and the second write would still erase the first -- the exact bug
-- this function exists to close, moved from seconds wide to milliseconds.
create or replace function public.fh_put_v2(body text, baserev bigint, device text)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  fid    text;
  cur    bigint;
  stored bigint;
begin
  select m.family_id into fid from public.family_hub_members m where m.user_id = auth.uid();
  if fid is null then raise exception 'not on a family list' using errcode = '42501'; end if;

  select s.rev into cur from public.family_hub_state s
   where s.family_id = fid for update;

  -- No board yet: this device seeds it. The on-conflict-do-nothing clause covers
  -- two devices seeding at the same instant; the loser is told to merge instead.
  if cur is null then
    insert into public.family_hub_state (family_id, payload, rev, updated_by, updated_at)
    values (fid, body, 1, device, now())
    on conflict (family_id) do nothing;
    if found then
      return jsonb_build_object('rev', 1, 'conflict', false, 'server_now', now());
    end if;
    select s.rev into cur from public.family_hub_state s where s.family_id = fid;
    return jsonb_build_object('rev', cur, 'conflict', true, 'server_now', now());
  end if;

  if baserev is null or cur <> baserev then
    return jsonb_build_object('rev', cur, 'conflict', true, 'server_now', now());
  end if;

  update public.family_hub_state t
     set payload = body, rev = t.rev + 1, updated_by = device, updated_at = now()
   where t.family_id = fid
  returning t.rev into stored;
  return jsonb_build_object('rev', stored, 'conflict', false, 'server_now', now());
end;
$$;

-- ---------------------------------------------------------------------------
-- The daily log. The board holds only the CURRENT state plus a short activity
-- feed, so it cannot answer "what happened on the 4th" a month later. This
-- table keeps one row per change, for good, so usage can be studied later.
--
-- A browser cannot write files to a disk on its own, so the per-day file is
-- produced on demand from these rows rather than written as the day goes on.
--
-- entry_key makes the insert idempotent. A phone that saves successfully but
-- loses its connection before the log call lands will retry, and retrying must
-- not double-count anything.
create table if not exists family_hub_log (
  id         bigint generated always as identity primary key,
  family_id  text not null,
  entry_key  text not null,
  day        date not null,
  at         timestamptz not null,
  by_email   text,
  by_name    text,
  device     text,
  path       text not null,
  op         text not null,
  item_id    text,
  item_name  text,
  n          integer not null default 1,
  detail     jsonb,
  unique (family_id, entry_key)
);
create index if not exists family_hub_log_day_idx on family_hub_log (family_id, day);
-- Sealed off the same way as every other table here: the privilege is taken
-- away outright, AND row level security is switched on with no policies, so a
-- direct read is refused rather than quietly returning nothing. Supabase grants
-- new tables to anon and authenticated by default, which is what makes the
-- revoke necessary. Only the security definer functions below get in.
alter table family_hub_log enable row level security;
revoke all on table family_hub_log from anon, authenticated;

-- Writes a batch of changes. The email is taken from the family list rather
-- than from the caller, so a device cannot log a change as somebody else.
create or replace function public.fh_log(entries jsonb)
returns integer
language plpgsql security definer set search_path = '' as $$
declare
  fid     text;
  mail    text;
  written integer;
begin
  select m.family_id, m.email into fid, mail
    from public.family_hub_members m where m.user_id = auth.uid();
  if fid is null then raise exception 'not on a family list' using errcode = '42501'; end if;
  if entries is null or jsonb_typeof(entries) <> 'array' then
    raise exception 'the log needs an array of entries';
  end if;
  if jsonb_array_length(entries) > 500 then
    raise exception 'too many log entries in one call';
  end if;

  insert into public.family_hub_log
    (family_id, entry_key, day, at, by_email, by_name, device, path, op, item_id, item_name, n, detail)
  select fid,
         e->>'k',
         (e->>'day')::date,
         (e->>'at')::timestamptz,
         mail,
         left(coalesce(e->>'by_name', ''), 80),
         left(coalesce(e->>'device', ''), 80),
         left(e->>'path', 80),
         left(e->>'op', 16),
         left(coalesce(e->>'item_id', ''), 120),
         left(coalesce(e->>'item_name', ''), 200),
         coalesce((e->>'n')::integer, 1),
         e->'detail'
    from jsonb_array_elements(entries) e
   where e->>'k' is not null and e->>'path' is not null
     and e->>'op' is not null and e->>'day' is not null and e->>'at' is not null
  on conflict (family_id, entry_key) do nothing;
  get diagnostics written = row_count;
  return written;
end;
$$;

-- One day of the log, for this person's family only. This is what the per-day
-- file is built from.
create or replace function public.fh_log_day(d date)
returns table (at timestamptz, by_email text, by_name text, device text,
               path text, op text, item_id text, item_name text, n integer, detail jsonb)
language sql security definer set search_path = '' as $$
  select l.at, l.by_email, l.by_name, l.device, l.path, l.op,
         l.item_id, l.item_name, l.n, l.detail
    from public.family_hub_log l
    join public.family_hub_members m on m.family_id = l.family_id
   where m.user_id = auth.uid() and l.day = d
   order by l.at;
$$;

-- Which days have anything in them, newest first, so the app can offer a list
-- to download instead of making someone guess a date.
create or replace function public.fh_log_days()
returns table (day date, entries bigint)
language sql security definer set search_path = '' as $$
  select l.day, count(*)
    from public.family_hub_log l
    join public.family_hub_members m on m.family_id = l.family_id
   where m.user_id = auth.uid()
   group by l.day
   order by l.day desc
   limit 400;
$$;

-- ---------------------------------------------------------------------------
-- Sealing the day. A browser cannot be relied on to be awake at midnight, so
-- a scheduled job inside Postgres takes the snapshot instead. Each family is
-- sealed at 12:30am in ITS OWN timezone, and what it seals is the day that has
-- just ENDED. Half past midnight rather than just before it: a snapshot taken
-- at 11:59pm can never contain that day's last minute, and a little clearance
-- past midnight also absorbs a late-arriving write from a phone that was
-- offline. The job runs every hour at minute 30 and only acts on a family
-- whose local hour is 0, so daylight saving needs no maintenance here.
-- See LOG_SCHEDULE_SQL for the schedule.
alter table family_hub_state add column if not exists tz text;

create table if not exists family_hub_log_sealed (
  family_id text not null,
  day       date not null,
  sealed_at timestamptz not null default now(),
  entries   integer not null,
  doc       jsonb not null,
  primary key (family_id, day)
);
alter table family_hub_log_sealed enable row level security;
revoke all on table family_hub_log_sealed from anon, authenticated;

-- Seals one family's one day. Writing it again is harmless: if the day has
-- already been sealed with the same number of rows, nothing has changed and the
-- function does nothing.
create or replace function public.fh_seal_one(fid text, d date)
returns integer
language plpgsql security definer set search_path = '' as $$
declare
  cnt integer;
  doc jsonb;
begin
  select count(*) into cnt from public.family_hub_log l
   where l.family_id = fid and l.day = d;
  if cnt = 0 then return 0; end if;
  if exists (select 1 from public.family_hub_log_sealed z
              where z.family_id = fid and z.day = d and z.entries = cnt) then
    return 0;
  end if;
  select jsonb_agg(to_jsonb(x) order by x.at) into doc from (
    select l.at, l.by_email, l.by_name, l.device, l.path, l.op,
           l.item_id, l.item_name, l.n, l.detail
      from public.family_hub_log l
     where l.family_id = fid and l.day = d
  ) x;
  insert into public.family_hub_log_sealed (family_id, day, sealed_at, entries, doc)
  values (fid, d, now(), cnt, coalesce(doc, '[]'::jsonb))
  on conflict (family_id, day) do update
    set sealed_at = now(), entries = excluded.entries, doc = excluded.doc;
  return 1;
end;
$$;

-- What the scheduled job calls. Not granted to anybody: it runs as the
-- database owner from the schedule, never from a device.
create or replace function public.fh_seal_days()
returns integer
language plpgsql security definer set search_path = '' as $$
declare
  fam      record;
  localnow timestamp;
  today    date;
  n        integer := 0;
begin
  for fam in select s.family_id, coalesce(s.tz, 'America/Chicago') as tz
               from public.family_hub_state s loop
    begin
      localnow := now() at time zone fam.tz;
    exception when others then
      -- One family with a mistyped timezone must not stop every other family
      -- from being sealed.
      localnow := now() at time zone 'America/Chicago';
    end;
    if extract(hour from localnow) <> 0 then continue; end if;
    today := localnow::date;
    -- The day that just ended, sealed whole.
    n := n + public.fh_seal_one(fam.family_id, today - 1);
    -- And the one before it, refreshed. That costs nothing when nothing has
    -- changed, and it means a night the job did not run is not a lost day.
    n := n + public.fh_seal_one(fam.family_id, today - 2);
  end loop;
  return n;
end;
$$;

-- The sealed snapshot of one day, for this person's family. The app prefers
-- this over the live rows, and falls back to the live rows for today, which has
-- not been sealed yet.
create or replace function public.fh_sealed_day(d date)
returns jsonb
language sql security definer set search_path = '' as $$
  select jsonb_build_object('day', z.day, 'sealed_at', z.sealed_at,
                            'count', z.entries, 'entries', z.doc)
    from public.family_hub_log_sealed z
    join public.family_hub_members m on m.family_id = z.family_id
   where m.user_id = auth.uid() and z.day = d;
$$;

-- Which timezone the nightly seal runs on for this family.
create or replace function public.fh_set_tz(zone text)
returns text
language plpgsql security definer set search_path = '' as $$
declare fid text;
begin
  select m.family_id into fid from public.family_hub_members m where m.user_id = auth.uid();
  if fid is null then raise exception 'not on a family list' using errcode = '42501'; end if;
  -- Refuse anything Postgres does not recognise, rather than storing a typo
  -- that would quietly seal the day at the wrong hour for ever.
  begin
    perform now() at time zone zone;
  exception when others then
    raise exception 'that is not a timezone Postgres knows';
  end;
  update public.family_hub_state set tz = zone where family_id = fid;
  return zone;
end;
$$;

create or replace function public.fh_get_tz()
returns text
language sql security definer set search_path = '' as $$
  select coalesce(s.tz, 'America/Chicago')
    from public.family_hub_state s
    join public.family_hub_members m on m.family_id = s.family_id
   where m.user_id = auth.uid();
$$;

-- Signed-in members only. Supabase grants new functions to anon by default,
-- so that grant is taken back explicitly.
revoke all on function public.fh_me() from public, anon;
revoke all on function public.fh_setup(text, text) from public, anon;
revoke all on function public.fh_meta() from public, anon;
revoke all on function public.fh_meta_v2() from public, anon;
revoke all on function public.fh_log(jsonb) from public, anon;
revoke all on function public.fh_sealed_day(date) from public, anon;
revoke all on function public.fh_set_tz(text) from public, anon;
revoke all on function public.fh_get_tz() from public, anon;
-- The sealing functions run from the schedule as the database owner. No
-- device ever calls them, so no device is allowed to.
revoke all on function public.fh_seal_one(text, date) from public, anon, authenticated;
revoke all on function public.fh_seal_days() from public, anon, authenticated;
revoke all on function public.fh_log_day(date) from public, anon;
revoke all on function public.fh_log_days() from public, anon;
revoke all on function public.fh_put_v2(text, bigint, text) from public, anon;
revoke all on function public.fh_get() from public, anon;
revoke all on function public.fh_put(text, bigint, text) from public, anon;
revoke all on function public.fh_members() from public, anon;
revoke all on function public.fh_set_member(text, text) from public, anon;
revoke all on function public.fh_remove_member(text) from public, anon;
revoke all on function public.fh_get_settings() from public, anon;
revoke all on function public.fh_put_settings(jsonb) from public, anon;
grant execute on function public.fh_me() to authenticated;
grant execute on function public.fh_setup(text, text) to authenticated;
grant execute on function public.fh_meta() to authenticated;
grant execute on function public.fh_meta_v2() to authenticated;
grant execute on function public.fh_log(jsonb) to authenticated;
grant execute on function public.fh_sealed_day(date) to authenticated;
grant execute on function public.fh_set_tz(text) to authenticated;
grant execute on function public.fh_get_tz() to authenticated;
grant execute on function public.fh_log_day(date) to authenticated;
grant execute on function public.fh_log_days() to authenticated;
grant execute on function public.fh_put_v2(text, bigint, text) to authenticated;
grant execute on function public.fh_get() to authenticated;
grant execute on function public.fh_put(text, bigint, text) to authenticated;
grant execute on function public.fh_members() to authenticated;
grant execute on function public.fh_set_member(text, text) to authenticated;
grant execute on function public.fh_remove_member(text) to authenticated;
grant execute on function public.fh_get_settings() to authenticated;
grant execute on function public.fh_put_settings(jsonb) to authenticated;