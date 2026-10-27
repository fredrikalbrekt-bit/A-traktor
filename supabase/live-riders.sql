-- Slowlane: förare som syns för andra inom 30 km, och för sina grupper i hela Sverige, medan appen
-- är öppen, grupper med träffar och notiser om nya träffar. Kräver inloggning med Google.
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

-- Träffar i en grupp: plats, tid och vilka som kommer. Syns för gruppen tills 3 timmar efter
-- starttiden och raderas ett dygn efter den.
create table if not exists public.meetups (
  id uuid primary key default gen_random_uuid(),
  group_id uuid not null references public.groups (id) on delete cascade,
  creator uuid not null references auth.users (id) on delete cascade,
  title text not null check (char_length(btrim(title)) between 2 and 40),
  pos extensions.geography(point, 4326) not null,
  starts_at timestamptz not null,
  created_at timestamptz not null default now()
);
create index if not exists meetups_group_idx on public.meetups (group_id, starts_at);
create table if not exists public.meetup_answers (
  meetup_id uuid not null references public.meetups (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  coming boolean not null,
  answered_at timestamptz not null default now(),
  primary key (meetup_id, user_id)
);
-- Varje träff ger notiser en gång
alter table public.meetups add column if not exists notified_at timestamptz;

-- Telefoner som vill ha notiser om nya träffar. Adressen kommer från telefonens notistjänst
-- (Apple, Google, Mozilla, Microsoft) och nycklarna krypterar innehållet så att bara telefonen kan läsa det.
-- Sparas om varje gång appen startas, och tas bort om appen inte har öppnats på 90 dagar.
create table if not exists public.push_subs (
  endpoint text primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  p256dh text not null,
  auth text not null,
  lang text not null default 'sv' check (lang in ('sv', 'en')),
  saved_at timestamptz not null default now()
);
create index if not exists push_subs_user_idx on public.push_subs (user_id);

-- Tabellerna nås bara via funktionerna nedan, aldrig direkt från appen
alter table public.riders enable row level security;
alter table public.blocks enable row level security;
alter table public.ride_last enable row level security;
alter table public.groups enable row level security;
alter table public.group_members enable row level security;
alter table public.meetups enable row level security;
alter table public.meetup_answers enable row level security;
alter table public.push_subs enable row level security;
revoke all on public.riders, public.blocks, public.ride_last, public.groups, public.group_members,
              public.meetups, public.meetup_answers, public.push_subs from anon, authenticated;

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

-- ---------- Träffar ----------
-- Alla i gruppen kan skapa träffar, högst 10 kommande per grupp. Skaparen och gruppens skapare kan ta bort dem.

create or replace function public.meetup_create(
  p_group uuid, p_title text, p_lat double precision, p_lng double precision, p_starts timestamptz)
returns uuid
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  me uuid := public.google_me();
  v_id uuid;
begin
  if not exists (select 1 from public.group_members m where m.group_id = p_group and m.user_id = me) then
    raise sqlstate 'PT403' using message = 'not a member';
  end if;
  if char_length(btrim(coalesce(p_title, ''))) not between 2 and 40 then
    raise sqlstate 'PT400' using message = 'bad title';
  end if;
  if p_starts is null or p_starts < now() - interval '10 minutes' or p_starts > now() + interval '30 days' then
    raise sqlstate 'PT400' using message = 'bad time';
  end if;
  if p_lat is null or p_lng is null or p_lat not between -90 and 90 or p_lng not between -180 and 180 then
    raise sqlstate 'PT400' using message = 'bad place';
  end if;
  if (select count(*) from public.meetups x where x.group_id = p_group and x.starts_at > now() - interval '3 hours') >= 10 then
    raise sqlstate 'PT409' using message = 'too many meetups';
  end if;
  insert into public.meetups (group_id, creator, title, pos, starts_at)
  values (p_group, me, btrim(p_title), st_setsrid(st_makepoint(p_lng, p_lat), 4326)::geography, p_starts)
  returning id into v_id;
  insert into public.meetup_answers (meetup_id, user_id, coming) values (v_id, me, true);
  return v_id;
end;
$$;

-- Kommande träffar i alla mina grupper. Svar från den som lämnat gruppen räknas inte.
create or replace function public.meetup_list()
returns table (id uuid, group_id uuid, group_name text, title text, lat double precision, lng double precision,
               starts_at timestamptz, creator_nick text, can_delete boolean, coming integer, my_answer boolean)
language plpgsql
security definer
set search_path = public, extensions
as $$
#variable_conflict use_column
declare
  me uuid := public.google_me();
begin
  return query
    select u.id, u.group_id, g.name, u.title, st_y(u.pos::geometry), st_x(u.pos::geometry), u.starts_at,
           cm.nick, (u.creator = me or g.owner = me),
           (select count(*)::integer from public.meetup_answers a
            join public.group_members gm on gm.group_id = u.group_id and gm.user_id = a.user_id
            where a.meetup_id = u.id and a.coming),
           (select a.coming from public.meetup_answers a where a.meetup_id = u.id and a.user_id = me)
    from public.meetups u
    join public.groups g on g.id = u.group_id
    join public.group_members mine on mine.group_id = u.group_id and mine.user_id = me
    left join public.group_members cm on cm.group_id = u.group_id and cm.user_id = u.creator
    where u.starts_at > now() - interval '3 hours'
    order by u.starts_at
    limit 50;
end;
$$;

-- Träffens grupp, om träffen finns kvar och jag är med i gruppen. Annars fel.
create or replace function public.meetup_group(p_meetup uuid, me uuid)
returns uuid
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_group uuid;
begin
  select u.group_id into v_group from public.meetups u where u.id = p_meetup and u.starts_at > now() - interval '3 hours';
  if v_group is null then
    raise sqlstate 'PT404' using message = 'no such meetup';
  end if;
  if not exists (select 1 from public.group_members m where m.group_id = v_group and m.user_id = me) then
    raise sqlstate 'PT403' using message = 'not a member';
  end if;
  return v_group;
end;
$$;

create or replace function public.meetup_people(p_meetup uuid)
returns table (nick text, coming boolean, is_me boolean)
language plpgsql
security definer
set search_path = public
as $$
#variable_conflict use_column
declare
  me uuid := public.google_me();
  v_group uuid := public.meetup_group(p_meetup, me);
begin
  return query
    select gm.nick, a.coming, a.user_id = me
    from public.meetup_answers a
    join public.group_members gm on gm.group_id = v_group and gm.user_id = a.user_id
    where a.meetup_id = p_meetup
    order by a.coming desc, a.answered_at;
end;
$$;

create or replace function public.meetup_answer(p_meetup uuid, p_coming boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid := public.google_me();
begin
  perform public.meetup_group(p_meetup, me);
  insert into public.meetup_answers (meetup_id, user_id, coming) values (p_meetup, me, coalesce(p_coming, false))
  on conflict on constraint meetup_answers_pkey do update set coming = excluded.coming, answered_at = now();
end;
$$;

create or replace function public.meetup_delete(p_meetup uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid := public.google_me();
begin
  if not exists (select 1 from public.meetups u where u.id = p_meetup) then
    raise sqlstate 'PT404' using message = 'no such meetup';
  end if;
  delete from public.meetups u
  where u.id = p_meetup
    and (u.creator = me or exists (select 1 from public.groups g where g.id = u.group_id and g.owner = me));
  if not found then
    raise sqlstate 'PT403' using message = 'not allowed';
  end if;
end;
$$;

-- ---------- Notiser om nya träffar ----------
-- Appen sparar telefonens notisadress. När en träff skapas anropar databasen notisfunktionen
-- (supabase/functions/meetup-push) med en hemlighet som bara databasen och Vault känner till.
-- Funktionen hämtar mottagarna med push_job och skickar notiserna.

-- Bara kända notistjänster, så att funktionen aldrig skickar något till en adress som någon hittat på
create or replace function public.push_host_ok(p_endpoint text)
returns boolean
language sql
immutable
as $$
  select coalesce(char_length(p_endpoint) <= 1000 and p_endpoint ~
    '^https://(fcm\.googleapis\.com|updates\.push\.services\.mozilla\.com|web\.push\.apple\.com|[a-z0-9-]+\.notify\.windows\.com)/', false);
$$;

-- Högst 10 telefoner per konto: den som inte har öppnat appen på längst tid får ge plats.
-- Byter telefonen konto flyttas adressen till det nya kontot.
create or replace function public.push_save(p_endpoint text, p_p256dh text, p_auth text, p_lang text default 'sv')
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  me uuid := public.google_me();
begin
  if not public.push_host_ok(p_endpoint) then
    raise sqlstate 'PT400' using message = 'bad endpoint';
  end if;
  if coalesce(char_length(p_p256dh), 0) not between 80 and 100 or coalesce(char_length(p_auth), 0) not between 16 and 30 then
    raise sqlstate 'PT400' using message = 'bad keys';
  end if;
  insert into public.push_subs (endpoint, user_id, p256dh, auth, lang)
  values (p_endpoint, me, p_p256dh, p_auth, case when p_lang = 'en' then 'en' else 'sv' end)
  on conflict (endpoint) do update
    set user_id = excluded.user_id, p256dh = excluded.p256dh, auth = excluded.auth, lang = excluded.lang, saved_at = now();
  delete from public.push_subs s
  where s.user_id = me
    and s.endpoint not in (select x.endpoint from public.push_subs x where x.user_id = me order by x.saved_at desc limit 10);
end;
$$;

create or replace function public.push_delete(p_endpoint text)
returns void
language sql
security definer
set search_path = public
as $$
  delete from public.push_subs where endpoint = p_endpoint and user_id = auth.uid();
$$;

-- Hemligheten mellan databasen och notisfunktionen. Skapas första gången och ligger krypterad i Vault.
do $$
begin
  if not exists (select 1 from vault.secrets where name = 'slowlane_push_hook') then
    perform vault.create_secret(encode(extensions.gen_random_bytes(32), 'hex'), 'slowlane_push_hook', 'Slowlane: databasen till notisfunktionen');
  end if;
end
$$;

-- Jämför hashar, så att svarstiden inte avslöjar hur mycket av hemligheten som stämmer
create or replace function public.push_hook_ok(p_secret text)
returns boolean
language sql
stable
security definer
set search_path = public, extensions
as $$
  select p_secret is not null and exists (
    select 1 from vault.decrypted_secrets s
    where s.name = 'slowlane_push_hook' and digest(s.decrypted_secret, 'sha256') = digest(p_secret, 'sha256'));
$$;

-- Mottagarna för en ny träff: alla i gruppen med notiser påslagna, utom den som skapade träffen och
-- den som har blockerat hen. Träffen markeras, så ett nytt anrop ger inga mottagare.
create or replace function public.push_job(p_meetup uuid, p_secret text)
returns table (endpoint text, p256dh text, auth text, lang text, title text, group_name text, creator_nick text, starts_at timestamptz)
language plpgsql
security definer
set search_path = public
as $$
#variable_conflict use_column
declare
  v public.meetups;
begin
  if not public.push_hook_ok(p_secret) then
    raise sqlstate 'PT403' using message = 'bad secret';
  end if;
  update public.meetups u set notified_at = now()
  where u.id = p_meetup and u.notified_at is null and u.created_at > now() - interval '1 hour'
  returning u.* into v;
  if not found then
    return;
  end if;
  return query
    select s.endpoint, s.p256dh, s.auth, s.lang, v.title, g.name, cm.nick, v.starts_at
    from public.group_members gm
    join public.push_subs s on s.user_id = gm.user_id
    join public.groups g on g.id = v.group_id
    left join public.group_members cm on cm.group_id = v.group_id and cm.user_id = v.creator
    where gm.group_id = v.group_id and gm.user_id <> v.creator
      and not exists (select 1 from public.blocks b where b.blocker = gm.user_id and b.blocked = v.creator);
end;
$$;

-- Adresser som notistjänsten säger inte finns längre (appen avinstallerad, notiser avstängda)
create or replace function public.push_gone(p_endpoints text[], p_secret text)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public.push_hook_ok(p_secret) then
    raise sqlstate 'PT403' using message = 'bad secret';
  end if;
  delete from public.push_subs where endpoint = any(p_endpoints);
end;
$$;

-- När en träff skapas: be notisfunktionen skicka, om någon i gruppen vill ha notiser.
-- pg_net skickar anropet först när träffen är sparad. Går något fel här skapas träffen ändå.
-- x-region: funktionen körs i Irland, där resten av uppgifterna finns. Svaren hamnar i net._http_response.
create extension if not exists pg_net;
create or replace function public.meetup_push_hook()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_secret text;
begin
  if not exists (select 1 from public.group_members gm join public.push_subs s on s.user_id = gm.user_id
                 where gm.group_id = new.group_id and gm.user_id <> new.creator) then
    return null;
  end if;
  select s.decrypted_secret into v_secret from vault.decrypted_secrets s where s.name = 'slowlane_push_hook';
  perform net.http_post(
    url := 'https://whpfdexdxwumaiiriqkt.supabase.co/functions/v1/meetup-push',
    body := jsonb_build_object('meetup', new.id),
    headers := jsonb_build_object('Content-Type', 'application/json', 'x-region', 'eu-west-1', 'x-slowlane-hook', v_secret),
    timeout_milliseconds := 10000);
  return null;
exception when others then
  raise warning 'slowlane push: %', sqlerrm;
  return null;
end;
$$;
drop trigger if exists meetups_push on public.meetups;
create trigger meetups_push after insert on public.meetups for each row execute function public.meetup_push_hook();

-- ---------- Rättigheter ----------
revoke execute on function public.google_me() from public, anon, authenticated;
revoke execute on function public.clean_nick(text) from public, anon, authenticated;
revoke execute on function public.clean_code(text) from public, anon, authenticated;
revoke execute on function public.new_group_code() from public, anon, authenticated;
revoke execute on function public.meetup_group(uuid, uuid) from public, anon, authenticated;
revoke execute on function public.push_host_ok(text) from public, anon, authenticated;
revoke execute on function public.push_hook_ok(text) from public, anon, authenticated;
revoke execute on function public.meetup_push_hook() from public, anon, authenticated;

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
revoke execute on function public.meetup_create(uuid, text, double precision, double precision, timestamptz) from public, anon;
revoke execute on function public.meetup_list() from public, anon;
revoke execute on function public.meetup_people(uuid) from public, anon;
revoke execute on function public.meetup_answer(uuid, boolean) from public, anon;
revoke execute on function public.meetup_delete(uuid) from public, anon;
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
grant execute on function public.meetup_create(uuid, text, double precision, double precision, timestamptz) to authenticated;
grant execute on function public.meetup_list() to authenticated;
grant execute on function public.meetup_people(uuid) to authenticated;
grant execute on function public.meetup_answer(uuid, boolean) to authenticated;
grant execute on function public.meetup_delete(uuid) to authenticated;
revoke execute on function public.push_save(text, text, text, text) from public, anon;
revoke execute on function public.push_delete(text) from public, anon;
grant execute on function public.push_save(text, text, text, text) to authenticated;
grant execute on function public.push_delete(text) to authenticated;
-- Notisfunktionen anropar med den publika nyckeln. Det är hemligheten som ger tillgång.
revoke execute on function public.push_job(uuid, text) from public, authenticated;
revoke execute on function public.push_gone(text[], text) from public, authenticated;
grant execute on function public.push_job(uuid, text) to anon;
grant execute on function public.push_gone(text[], text) to anon;

-- ---------- Städning ----------
-- Varje natt. Senast godkända position sparas bara ett dygn: efter det släpper
-- hoppkontrollen ändå igenom hela Sverige. Träffar raderas ett dygn efter starttiden, och
-- notisadresser till telefoner som inte har öppnat appen på 90 dagar.
-- Anonyma konton från äldre versioner kan inte synas längre och tas bort när de är
-- 30 dagar gamla, med blockeringar och allt.
create or replace function public.cleanup_riders()
returns integer
language sql
security definer
set search_path = public
as $$
  with old_pos as (
    delete from public.ride_last where pinged_at < now() - interval '1 day'),
  old_meets as (
    delete from public.meetups where starts_at < now() - interval '1 day'),
  old_push as (
    delete from public.push_subs where saved_at < now() - interval '90 days'),
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
