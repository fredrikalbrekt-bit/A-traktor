-- Slowlane: förare som syns för andra inom 30 km medan appen är öppen.
-- Körs en gång i Supabase → SQL Editor. Går att köra om.

create extension if not exists postgis with schema extensions;

create table if not exists public.riders (
  id uuid primary key references auth.users (id) on delete cascade,
  nick text not null check (char_length(btrim(nick)) between 3 and 16),
  vehicle text not null check (vehicle in ('epa', 'moped1', 'moped2', 'mopedbil')),
  pos extensions.geography(point, 4326) not null,
  heading real,
  speed real,
  updated_at timestamptz not null default now()
);
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

-- Tabellerna nås bara via funktionerna nedan, aldrig direkt från appen
alter table public.riders enable row level security;
alter table public.blocks enable row level security;
alter table public.ride_last enable row level security;
revoke all on public.riders, public.blocks, public.ride_last from anon, authenticated;

-- Spara min position och få tillbaka alla andra inom 30 km från den
create or replace function public.ride_ping(
  p_nick text, p_vehicle text, p_lat double precision, p_lng double precision,
  p_heading real default null, p_speed real default null)
returns table (id uuid, nick text, vehicle text, lat double precision, lng double precision,
               heading real, speed real, updated_at timestamptz)
language plpgsql
security definer
set search_path = public, extensions
as $$
#variable_conflict use_column
declare
  me uuid := auth.uid();
  here geography := st_setsrid(st_makepoint(p_lng, p_lat), 4326)::geography;
  prev record;
begin
  if me is null then raise exception 'not signed in'; end if;

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

  insert into public.riders (id, nick, vehicle, pos, heading, speed, updated_at)
  values (me, btrim(p_nick), p_vehicle, here, p_heading, p_speed, now())
  on conflict on constraint riders_pkey do update
    set nick = excluded.nick, vehicle = excluded.vehicle, pos = excluded.pos,
        heading = excluded.heading, speed = excluded.speed, updated_at = now();

  -- Appar som stängts utan att hinna säga till lämnar inget kvar
  delete from public.riders where riders.updated_at < now() - interval '5 minutes';

  return query
    select r.id, r.nick, r.vehicle,
           st_y(r.pos::geometry), st_x(r.pos::geometry),
           r.heading, r.speed, r.updated_at
    from public.riders r
    where r.id <> me
      and r.updated_at > now() - interval '60 seconds'
      and st_dwithin(r.pos, here, 30000)
      and not exists (select 1 from public.blocks b
                      where (b.blocker = me and b.blocked = r.id)
                         or (b.blocker = r.id and b.blocked = me))
    order by st_distance(r.pos, here)
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

revoke execute on function public.ride_ping(text, text, double precision, double precision, real, real) from public, anon;
revoke execute on function public.ride_stop() from public, anon;
revoke execute on function public.block_rider(uuid) from public, anon;
grant execute on function public.ride_ping(text, text, double precision, double precision, real, real) to authenticated;
grant execute on function public.ride_stop() to authenticated;
grant execute on function public.block_rider(uuid) to authenticated;

-- Städning: anonyma konton som inte synts på 30 dagar tas bort, med blockeringar och allt.
-- Kommer de tillbaka får de ett nytt konto automatiskt.
create or replace function public.cleanup_riders()
returns integer
language sql
security definer
set search_path = public
as $$
  with gone as (
    delete from auth.users u
    where u.is_anonymous
      and u.created_at < now() - interval '30 days'
      and not exists (select 1 from public.ride_last l
                      where l.id = u.id and l.pinged_at > now() - interval '30 days')
    returning 1)
  select count(*)::integer from gone;
$$;
revoke execute on function public.cleanup_riders() from public, anon, authenticated;

-- Kör städningen varje natt kl. 03:23
create extension if not exists pg_cron with schema pg_catalog;
grant usage on schema cron to postgres;
grant all privileges on all tables in schema cron to postgres;
select cron.schedule('slowlane-cleanup', '23 3 * * *', 'select public.cleanup_riders()');
