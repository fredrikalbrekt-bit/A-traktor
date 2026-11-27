-- Testar Slowlanes grupper med fyra påhittade Google-konton och ett anonymt konto.
-- Allt rullas tillbaka: databasen ser likadan ut efteråt.
-- Förväntat svar: ett "fel" med texten ALLA GRUPPTESTER OK. Står det FEL: ... är något trasigt.

create function pg_temp.act(u uuid) returns void language sql as $f$
  select set_config('request.jwt.claims', json_build_object('sub', u, 'role', 'authenticated')::text, true);
$f$;
create function pg_temp.expect(ok boolean, what text) returns void language plpgsql as $f$
begin
  if ok is not true then raise exception 'FEL: %', what; end if;
end;
$f$;

do $$
declare
  a uuid := gen_random_uuid();   -- skapar gruppen, Malmö
  b uuid := gen_random_uuid();   -- medlem, nära A, syns bara för grupper
  c uuid := gen_random_uuid();   -- okänd, nära A
  e uuid := gen_random_uuid();   -- medlem, Luleå
  d uuid := gen_random_uuid();   -- anonymt konto
  v_gid uuid; v_code text; v_code2 text; v_seen text; v_n integer;
begin
  -- Rättigheter
  perform pg_temp.expect(to_regprocedure('public.ride_ping(text,text,double precision,double precision,real,real)') is null, 'gamla ride_ping finns kvar');
  perform pg_temp.expect(not has_function_privilege('authenticated', 'public.google_me()', 'execute'), 'appen kan anropa google_me');
  perform pg_temp.expect(not has_function_privilege('authenticated', 'public.new_group_code()', 'execute'), 'appen kan anropa new_group_code');
  perform pg_temp.expect(not has_function_privilege('anon', 'public.group_join(text,text)', 'execute'), 'utan konto kan man gå med');
  perform pg_temp.expect(has_function_privilege('authenticated', 'public.group_join(text,text)', 'execute'), 'inloggade kan inte gå med');

  insert into auth.users (id, aud, role, email, is_anonymous) values
    (a, 'authenticated', 'authenticated', 'slowlane-test-a@example.invalid', false),
    (b, 'authenticated', 'authenticated', 'slowlane-test-b@example.invalid', false),
    (c, 'authenticated', 'authenticated', 'slowlane-test-c@example.invalid', false),
    (e, 'authenticated', 'authenticated', 'slowlane-test-e@example.invalid', false),
    (d, 'authenticated', 'authenticated', null, true);
  insert into auth.identities (provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
  select 'slowlane-test-' || u, u, jsonb_build_object('sub', 'slowlane-test-' || u), 'google', now(), now(), now()
  from unnest(array[a, b, c, e]) u;

  -- Skapa och gå med
  perform pg_temp.act(a);
  select x.id, x.code into v_gid, v_code from public.group_create('Testgänget', 'TestA') x;
  perform pg_temp.expect(v_code ~ '^[A-HJ-NP-Z2-9]{8}$', 'koden har inte 8 tydliga tecken: ' || coalesce(v_code, '-'));
  begin perform public.group_create('x'); perform pg_temp.expect(false, 'för kort namn gick'); exception when sqlstate 'PT400' then null; end;

  perform pg_temp.act(b);
  perform pg_temp.expect((select x.name from public.group_peek(lower(v_code)) x) = 'Testgänget', 'peek med små bokstäver');
  perform public.group_join(v_code, 'TestB');
  perform pg_temp.act(e);
  perform public.group_join(substr(v_code, 1, 4) || '-' || substr(v_code, 5), 'TestE');
  perform public.group_join(v_code, 'TestE');   -- två gånger gör inget

  perform pg_temp.act(d);
  begin perform public.group_join(v_code, 'TestD'); perform pg_temp.expect(false, 'anonymt konto gick med'); exception when sqlstate 'PT403' then null; end;
  perform pg_temp.act(c);
  begin perform public.group_join('ZZZZZZZZ', 'TestC'); perform pg_temp.expect(false, 'fel kod gick'); exception when sqlstate 'PT404' then null; end;
  begin perform public.group_people(v_gid); perform pg_temp.expect(false, 'icke-medlem såg medlemmarna'); exception when sqlstate 'PT403' then null; end;

  -- Bara skaparen ser koden
  perform pg_temp.act(e);
  perform pg_temp.expect((select x.code from public.group_list() x) is null, 'medlem ser koden');
  perform pg_temp.expect((select x.members from public.group_list() x) = 3, 'gruppen har inte 3 medlemmar');
  perform pg_temp.act(a);
  perform pg_temp.expect((select x.code from public.group_list() x) = v_code, 'skaparen ser inte koden');
  perform pg_temp.expect((select string_agg(x.nick, ',' order by x.is_owner desc, x.nick) from public.group_people(v_gid) x) = 'TestA,TestB,TestE', 'medlemslistan');

  -- Synlighet. Första varvet registrerar alla, andra varvet visar vem som ser vem.
  perform pg_temp.act(a); perform public.ride_ping('TestA', 'epa', 55.605, 13.0, null, null, 'all');
  perform pg_temp.act(b); perform public.ride_ping('TestB', 'moped2', 55.62, 13.05, null, null, 'groups');
  perform pg_temp.act(c); perform public.ride_ping('TestC', 'mopedbil', 55.59, 12.98);   -- som version 34: utan val
  perform pg_temp.act(e); perform public.ride_ping('TestE', 'moped1', 65.58, 22.15, null, null, 'all');
  update public.ride_last set pinged_at = now() - interval '20 seconds' where id in (a, b, c, e);

  perform pg_temp.act(a);
  select string_agg(x.nick || case when x.in_group then '*' || x.group_name else '' end, ',' order by x.nick) into v_seen from public.ride_ping('TestA', 'epa', 55.605, 13.0, null, null, 'all') x;
  perform pg_temp.expect(v_seen = 'TestB*Testgänget,TestC,TestE*Testgänget', 'A ska se B och E (grupp) och C (nära), såg ' || coalesce(v_seen, 'ingen'));
  perform pg_temp.act(b);
  select string_agg(x.nick || case when x.in_group then '*' else '' end, ',' order by x.nick) into v_seen from public.ride_ping('TestB', 'moped2', 55.62, 13.05, null, null, 'groups') x;
  perform pg_temp.expect(v_seen = 'TestA*,TestE*', 'B (bara grupper) ska se A och E, såg ' || coalesce(v_seen, 'ingen'));
  perform pg_temp.act(c);
  select string_agg(x.nick || case when x.in_group then '*' else '' end, ',' order by x.nick) into v_seen from public.ride_ping('TestC', 'mopedbil', 55.59, 12.98) x;
  perform pg_temp.expect(v_seen = 'TestA', 'C (okänd, nära) ska bara se A, såg ' || coalesce(v_seen, 'ingen'));
  perform pg_temp.act(e);
  select string_agg(x.nick || case when x.in_group then '*' else '' end, ',' order by x.nick) into v_seen from public.ride_ping('TestE', 'moped1', 65.58, 22.15, null, null, 'all') x;
  perform pg_temp.expect(v_seen = 'TestA*,TestB*', 'E (Luleå) ska se A och B, såg ' || coalesce(v_seen, 'ingen'));

  -- Blockering gäller även i grupper
  perform pg_temp.act(a); perform public.block_rider(e);
  update public.ride_last set pinged_at = now() - interval '20 seconds' where id in (a, e);
  select string_agg(x.nick, ',' order by x.nick) into v_seen from public.ride_ping('TestA', 'epa', 55.605, 13.0, null, null, 'all') x;
  perform pg_temp.expect(v_seen = 'TestB,TestC', 'A har blockerat E men ser ' || coalesce(v_seen, 'ingen'));
  perform pg_temp.act(e);
  select string_agg(x.nick, ',' order by x.nick) into v_seen from public.ride_ping('TestE', 'moped1', 65.58, 22.15, null, null, 'all') x;
  perform pg_temp.expect(v_seen = 'TestB', 'E är blockerad av A men ser ' || coalesce(v_seen, 'ingen'));

  -- Ta bort medlemmar: bara skaparen, och inte sig själv
  perform pg_temp.act(e);
  begin perform public.group_kick(v_gid, b); perform pg_temp.expect(false, 'medlem kunde ta bort'); exception when sqlstate 'PT403' then null; end;
  perform pg_temp.act(a);
  begin perform public.group_kick(v_gid, a); perform pg_temp.expect(false, 'skaparen tog bort sig själv'); exception when sqlstate 'PT403' then null; end;
  perform public.group_kick(v_gid, b);
  update public.ride_last set pinged_at = now() - interval '20 seconds' where id = b;
  perform pg_temp.act(b);
  select count(*) into v_n from public.ride_ping('TestB', 'moped2', 55.62, 13.05, null, null, 'groups');
  perform pg_temp.expect(v_n = 0, 'B är borttagen men ser fortfarande ' || v_n);

  -- Ny kod: gamla slutar fungera, nya fungerar, bara skaparen får byta
  perform pg_temp.act(e);
  begin perform public.group_new_code(v_gid); perform pg_temp.expect(false, 'medlem bytte kod'); exception when sqlstate 'PT403' then null; end;
  perform pg_temp.act(a);
  v_code2 := public.group_new_code(v_gid);
  perform pg_temp.expect(v_code2 is not null and v_code2 <> v_code, 'ny kod');
  perform pg_temp.act(b);
  begin perform public.group_join(v_code, 'TestB'); perform pg_temp.expect(false, 'gamla koden fungerar'); exception when sqlstate 'PT404' then null; end;
  perform public.group_join(v_code2, 'TestB');

  -- Lämna: medlem går ut, skaparen tar bort gruppen
  perform pg_temp.act(e); perform public.group_leave(v_gid);
  perform pg_temp.act(a);
  perform pg_temp.expect((select x.members from public.group_list() x where x.id = v_gid) = 2, 'E lämnade inte');
  perform public.group_leave(v_gid);
  perform pg_temp.expect(not exists (select 1 from public.groups where id = v_gid), 'gruppen finns kvar när skaparen lämnat');

  -- Högst 5 egna grupper
  for i in 1..5 loop perform public.group_create('Grupp ' || i, 'TestA'); end loop;
  begin perform public.group_create('Grupp 6'); perform pg_temp.expect(false, 'sjätte gruppen gick'); exception when sqlstate 'PT409' then null; end;

  -- Radera kontot tar bort grupperna man skapat
  perform public.delete_me();
  perform pg_temp.expect(not exists (select 1 from public.groups where owner = a), 'grupper finns kvar efter radering');

  raise exception 'ALLA GRUPPTESTER OK (allt är tillbakarullat)';
end
$$;
