-- Slowlane: förare som syns för andra inom 30 km, och för sina grupper i hela Sverige, medan appen
-- är öppen. Kräver inloggning med Google.
-- Körs i Supabase → SQL Editor. Går att köra om.

create extension if not exists postgis with schema extensions;
create extension if not exists pgcrypto with schema extensions;

create table if not exists public.riders (
  id uuid primary key references auth.users (id) on delete cascade,
  nick text not null check (char_length(btrim(nick)) between 3 and 16),
  vehicle text not null check (vehicle in ('epa', 'moped1', 'moped2', 'mopedbil')),
  pos extensions.geography(point, 4326) not null,
  heading real,
  speed real,
  updated_at timestamptz not null default now()
);
-- all: syns för alla inom 30 km och för sina grupper. groups: bara för sina grupper.
alter table public.riders add column if not exists scope text not null default 'all' check (scope in ('all', 'groups'));
create index if not exists riders_pos_idx on public.riders using gist (pos);
create index if not exists riders_updated_idx on public.riders (updated_at);

create table if not exists public.blocks (
  blocker uuid not null references auth.users (id) on delete cascade,
  blocked uuid not null references auth.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker, blocked)
);

-- Senast godkända position per förare. Finns kvar när man slutar synas, så att
-- spärrarna i ride_ping inte går att komma runt med ride_stop.
create table if not exists public.ride_last (
  id uuid primary key references auth.users (id) on delete cascade,
  pos extensions.geography(point, 4326) not null,
  pinged_at timestamptz not null
);

-- Grupper. Man går med via en inbjudningskod som bara skaparen ser och kan byta.
-- Tar skaparen bort sitt konto försvinner gruppen.
create table if not exists public.groups (
  id uuid primary key default gen_random_uuid(),
  name text not null check (char_length(btrim(name)) between 2 and 24),
  code text not null unique,
  owner uuid not null references auth.users (id) on delete cascade,
  created_at timestamptz not null default now()
);
create table if not exists public.group_members (
  group_id uuid not null references public.groups (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  nick text,
  joined_at timestamptz not null default now(),
  primary key (group_id, user_id)
);
create index if not exists group_members_user_idx on public.group_members (user_id);

-- Tabellerna nås bara via funktionerna nedan, aldrig direkt från appen
alter table public.riders enable row level security;
alter table public.blocks enable row level security;
alter table public.ride_last enable row level security;
alter table public.groups enable row level security;
alter table public.group_members enable row level security;
revoke all on public.riders, public.blocks, public.ride_last, public.groups, public.group_members from anon, authenticated;

-- ---------- Hjälpfunktioner (bara för funktionerna nedan) ----------

-- Mitt id, men bara för Google-konton. Anonyma konton och e-postkonton går att skapa i mängd.
create or replace function public.google_me()
returns uuid
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  me uuid := auth.uid();
begin
  if me is null or not exists (select 1 from auth.identities i where i.user_id = me and i.provider = 'google') then
    raise sqlstate 'PT403' using message = 'sign in with Google';
  end if;
  return me;
end;
$$;

create or replace function public.clean_nick(p text)
returns text
language sql
immutable
as $$
  select case when char_length(btrim(coalesce(p, ''))) between 3 and 16 then btrim(p) end;
$$;

-- Koden skrivs ofta av för hand: små bokstäver, mellanslag och bindestreck gör inget
create or replace function public.clean_code(p text)
returns text
language sql
immutable
as $$
  select upper(regexp_replace(coalesce(p, ''), '[^A-Za-z0-9]', '', 'g'));
$$;

-- 8 tecken utan förväxlingsbara (0/O, 1/I)
create or replace function public.new_group_code()
returns text
language sql
volatile
set search_path = public, extensions
as $$
  select string_agg(substr('ABCDEFGHJKLMNPQRSTUVWXYZ23456789', 1 + get_byte(b, i) % 32, 1), '')
  from extensions.gen_random_bytes(8) b, generate_series(0, 7) i;
$$;

-- ---------- Position ----------

-- Spara min position och få tillbaka de andra jag får se: alla inom 30 km som syns för alla
-- (om jag själv gör det), och mina gruppkamrater var de än är.
drop function if exists public.ride_ping(text, text, double precision, double precision, real, real);
create or replace function public.ride_ping(
  p_nick text, p_vehicle text, p_lat double precision, p_lng double precision,
  p_heading real default null, p_speed real default null, p_scope text default 'all')
returns table (id uuid, nick text, vehicle text, lat double precision, lng double precision,
               heading real, speed real, updated_at timestamptz, in_group boolean, group_name text)
language plpgsql
security definer
set search_path = public, extensions
as $$
#variable_conflict use_column
declare
  me uuid := public.google_me();
  here geography := st_setsrid(st_makepoint(p_lng, p_lat), 4326)::geography;
  my_scope text := case when p_scope = 'groups' then 'groups' else 'all' end;
  prev record;
begin
  -- Högst en position per 10 sekunder, och inga hopp som inget fordon klarar
  -- (150 km/h plus 1 km för GPS-fel). Annars går det att svepa över landet och se alla.
  select l.pos, l.pinged_at into prev from public.ride_last l where l.id = me for update;
  if found then
    if prev.pinged_at > now() - interval '10 seconds' then
      raise sqlstate 'PT429' using message = 'too soon';
    end if;
    if st_distance(prev.pos, here) > 1000 + 150 / 3.6 * extract(epoch from now() - prev.pinged_at) then
      raise sqlstate 'PT422' using message = 'impossible jump';
    end if;
  end if;
  insert into public.ride_last (id, pos, pinged_at) values (me, here, now())
  on conflict on constraint ride_last_pkey do update set pos = excluded.pos, pinged_at = excluded.pinged_at;

  insert into public.riders (id, nick, vehicle, pos, heading, speed, updated_at, scope)
  values (me, btrim(p_nick), p_vehicle, here, p_heading, p_speed, now(), my_scope)
  on conflict on constraint riders_pkey do update
    set nick = excluded.nick, vehicle = excluded.vehicle, pos = excluded.pos,
        heading = excluded.heading, speed = excluded.speed, updated_at = now(), scope = excluded.scope;

  -- gruppkamraterna ser samma smeknamn som kartan
  update public.group_members set nick = btrim(p_nick)
  where user_id = me and nick is distinct from btrim(p_nick);

  -- Appar som stängts utan att hinna säga till lämnar inget kvar
  delete from public.riders where riders.updated_at < now() - interval '5 minutes';

  return query
    with mates as (
      select distinct on (b.user_id) b.user_id, g.name
      from public.group_members a
      join public.group_members b on b.group_id = a.group_id and b.user_id <> me
      join public.groups g on g.id = a.group_id
      where a.user_id = me
      order by b.user_id, g.created_at)
    select r.id, r.nick, r.vehicle,
           st_y(r.pos::geometry), st_x(r.pos::geometry),
           r.heading, r.speed, r.updated_at,
           m.user_id is not null, m.name
    from public.riders r
    left join mates m on m.user_id = r.id
    where r.id <> me
      and r.updated_at > now() - interval '60 seconds'
      and (m.user_id is not null
           or (my_scope = 'all' and r.scope = 'all' and st_dwithin(r.pos, here, 30000)))
      and not exists (select 1 from public.blocks b
                      where (b.blocker = me and b.blocked = r.id)
                         or (b.blocker = r.id and b.blocked = me))
    order by m.user_id is null, st_distance(r.pos, here)
    limit 300;
end;
$$;

create or replace function public.ride_stop()
returns void
language sql
security definer
set search_path = public, extensions
as $$
  delete from public.riders where id = auth.uid();
$$;

create or replace function public.block_rider(p_id uuid)
returns void
language sql
security definer
set search_path = public, extensions
as $$
  insert into public.blocks (blocker, blocked) values (auth.uid(), p_id) on conflict do nothing;
$$;

-- Radera mitt konto: position, blockeringar, grupper jag skapat och kopplingen till Google försvinner med kontot
create or replace function public.delete_me()
returns void
language sql
security definer
set search_path = public
as $$
  delete from auth.users where id = auth.uid();
$$;

-- ---------- Grupper ----------
-- Högst 5 egna grupper, 20 grupper per förare och 50 medlemmar per grupp.

create or replace function public.group_create(p_name text, p_nick text default null)
returns table (id uuid, name text, code text)
language plpgsql
security definer
set search_path = public
as $$
#variable_conflict use_column
declare
  me uuid := public.google_me();
  g public.groups;
begin
  if char_length(btrim(coalesce(p_name, ''))) not between 2 and 24 then
    raise sqlstate 'PT400' using message = 'bad name';
  end if;
  if (select count(*) from public.groups x where x.owner = me) >= 5
     or (select count(*) from public.group_members x where x.user_id = me) >= 20 then
    raise sqlstate 'PT409' using message = 'too many groups';
  end if;
  insert into public.groups (name, code, owner) values (btrim(p_name), public.new_group_code(), me) returning * into g;
  insert into public.group_members (group_id, user_id, nick) values (g.id, me, public.clean_nick(p_nick));
  return query select g.id, g.name, g.code;
end;
$$;

-- Vilken grupp hör koden till? Visas innan man går med.
create or replace function public.group_peek(p_code text)
returns table (name text, members integer)
language plpgsql
security definer
set search_path = public
as $$
#variable_conflict use_column
begin
  perform public.google_me();
  return query
    select g.name, (select count(*)::integer from public.group_members m where m.group_id = g.id)
    from public.groups g where g.code = public.clean_code(p_code);
end;
$$;

create or replace function public.group_join(p_code text, p_nick text default null)
returns table (id uuid, name text)
language plpgsql
security definer
set search_path = public
as $$
#variable_conflict use_column
declare
  me uuid := public.google_me();
  g public.groups;
begin
  select * into g from public.groups x where x.code = public.clean_code(p_code);
  if not found then
    raise sqlstate 'PT404' using message = 'no such group';
  end if;
  if not exists (select 1 from public.group_members m where m.group_id = g.id and m.user_id = me) then
    if (select count(*) from public.group_members m where m.group_id = g.id) >= 50 then
      raise sqlstate 'PT409' using message = 'group full';
    end if;
    if (select count(*) from public.group_members m where m.user_id = me) >= 20 then
      raise sqlstate 'PT409' using message = 'too many groups';
    end if;
    insert into public.group_members (group_id, user_id, nick) values (g.id, me, public.clean_nick(p_nick));
  end if;
  return query select g.id, g.name;
end;
$$;

-- Mina grupper. Koden syns bara för skaparen. Uppdaterar samtidigt mitt smeknamn i grupperna.
create or replace function public.group_list(p_nick text default null)
returns table (id uuid, name text, code text, is_owner boolean, members integer)
language plpgsql
security definer
set search_path = public
as $$
#variable_conflict use_column
declare
  me uuid := public.google_me();
  n text := public.clean_nick(p_nick);
begin
  if n is not null then
    update public.group_members set nick = n where user_id = me and nick is distinct from n;
  end if;
  return query
    select g.id, g.name, case when g.owner = me then g.code end, g.owner = me,
           (select count(*)::integer from public.group_members c where c.group_id = g.id)
    from public.group_members m join public.groups g on g.id = m.group_id
    where m.user_id = me
    order by g.created_at;
end;
$$;

create or replace function public.group_people(p_group uuid)
returns table (user_id uuid, nick text, is_owner boolean, is_me boolean)
language plpgsql
security definer
set search_path = public
as $$
#variable_conflict use_column
declare
  me uuid := public.google_me();
begin
  if not exists (select 1 from public.group_members m where m.group_id = p_group and m.user_id = me) then
    raise sqlstate 'PT403' using message = 'not a member';
  end if;
  return query
    select m.user_id, m.nick, m.user_id = g.owner, m.user_id = me
    from public.group_members m join public.groups g on g.id = m.group_id
    where m.group_id = p_group
    order by m.user_id = g.owner desc, m.joined_at;
end;
$$;

create or replace function public.group_kick(p_group uuid, p_user uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid := public.google_me();
begin
  if not exists (select 1 from public.groups g where g.id = p_group and g.owner = me) or p_user = me then
    raise sqlstate 'PT403' using message = 'not the owner';
  end if;
  delete from public.group_members where group_id = p_group and user_id = p_user;
end;
$$;

-- Ny kod: den gamla länken slutar fungera, men alla som är med stannar kvar
create or replace function public.group_new_code(p_group uuid)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid := public.google_me();
  c text;
begin
  update public.groups set code = public.new_group_code() where id = p_group and owner = me returning code into c;
  if c is null then
    raise sqlstate 'PT403' using message = 'not the owner';
  end if;
  return c;
end;
$$;

-- Lämnar skaparen tas gruppen bort för alla
create or replace function public.group_leave(p_group uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid := public.google_me();
begin
  if exists (select 1 from public.groups g where g.id = p_group and g.owner = me) then
    delete from public.groups where id = p_group;
  else
    delete from public.group_members where group_id = p_group and user_id = me;
  end if;
end;
$$;

-- ---------- Rättigheter ----------
revoke execute on function public.google_me() from public, anon, authenticated;
revoke execute on function public.clean_nick(text) from public, anon, authenticated;
revoke execute on function public.clean_code(text) from public, anon, authenticated;
revoke execute on function public.new_group_code() from public, anon, authenticated;

revoke execute on function public.ride_ping(text, text, double precision, double precision, real, real, text) from public, anon;
revoke execute on function public.ride_stop() from public, anon;
revoke execute on function public.block_rider(uuid) from public, anon;
revoke execute on function public.delete_me() from public, anon;
revoke execute on function public.group_create(text, text) from public, anon;
revoke execute on function public.group_peek(text) from public, anon;
revoke execute on function public.group_join(text, text) from public, anon;
revoke execute on function public.group_list(text) from public, anon;
revoke execute on function public.group_people(uuid) from public, anon;
revoke execute on function public.group_kick(uuid, uuid) from public, anon;
revoke execute on function public.group_new_code(uuid) from public, anon;
revoke execute on function public.group_leave(uuid) from public, anon;
grant execute on function public.ride_ping(text, text, double precision, double precision, real, real, text) to authenticated;
grant execute on function public.ride_stop() to authenticated;
grant execute on function public.block_rider(uuid) to authenticated;
grant execute on function public.delete_me() to authenticated;
grant execute on function public.group_create(text, text) to authenticated;
grant execute on function public.group_peek(text) to authenticated;
grant execute on function public.group_join(text, text) to authenticated;
grant execute on function public.group_list(text) to authenticated;
grant execute on function public.group_people(uuid) to authenticated;
grant execute on function public.group_kick(uuid, uuid) to authenticated;
grant execute on function public.group_new_code(uuid) to authenticated;
grant execute on function public.group_leave(uuid) to authenticated;

-- ---------- Städning ----------
-- Varje natt. Senast godkända position sparas bara ett dygn: efter det släpper
-- hoppkontrollen ändå igenom hela Sverige. Anonyma konton från äldre versioner kan inte synas
-- längre och tas bort när de är 30 dagar gamla, med blockeringar och allt.
create or replace function public.cleanup_riders()
returns integer
language sql
security definer
set search_path = public
as $$
  with old_pos as (
    delete from public.ride_last where pinged_at < now() - interval '1 day'),
  gone as (
    delete from auth.users u
    where u.is_anonymous and u.created_at < now() - interval '30 days'
    returning 1)
  select count(*)::integer from gone;
$$;
revoke execute on function public.cleanup_riders() from public, anon, authenticated;

-- Kör städningen varje natt kl. 03:23. pg_cron och rättigheterna sätts bara upp första gången:
-- körs de igen krockar de med Supabases egna rättigheter på cron.
do $$
begin
  if not exists (select 1 from pg_extension where extname = 'pg_cron') then
    create extension pg_cron with schema pg_catalog;
    grant usage on schema cron to postgres;
    grant all privileges on all tables in schema cron to postgres;
  end if;
end
$$;
select cron.schedule('slowlane-cleanup', '23 3 * * *', 'select public.cleanup_riders()');
