-- Testar gränserna för träffar och notiser, och städningen, med fyra påhittade Google-konton.
-- Allt rullas tillbaka: databasen ser likadan ut efteråt, och inga notiser skickas.
-- Förväntat svar: ett "fel" med texten ALLA GRÄNSTESTER OK. Står det FEL: ... är något trasigt.

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
  a uuid := gen_random_uuid();   -- skapar grupperna
  b uuid := gen_random_uuid();   -- medlem som skapar träffar
  c uuid := gen_random_uuid();   -- medlem med notiser
  g uuid := gen_random_uuid();   -- har God mode
  k text := repeat('k', 87);
  au text := repeat('a', 22);
  v_secret text; v_gid uuid; v_gid2 uuid; v_code text; v_m uuid; v_n integer; v_ids uuid[] := '{}';
begin
  -- Rättigheter och schemalagda jobb
  perform pg_temp.expect(not has_table_privilege('authenticated', 'public.meetup_log', 'select'), 'appen kan läsa meetup_log');
  perform pg_temp.expect(not has_function_privilege('authenticated', 'public.cleanup_live()', 'execute'), 'appen kan anropa cleanup_live');
  perform pg_temp.expect(not has_function_privilege('anon', 'public.cleanup_live()', 'execute'), 'utan konto kan man anropa cleanup_live');
  perform pg_temp.expect((select schedule from cron.job where jobname = 'slowlane-live') = '* * * * *', 'slowlane-live körs inte varje minut');
  perform pg_temp.expect((select schedule from cron.job where jobname = 'slowlane-cleanup') = '23 * * * *', 'slowlane-cleanup körs inte varje timme');
  perform pg_temp.expect(exists (select 1 from cron.job where jobname = 'slowlane-cron-log'), 'jobbet som rensar cron-loggen saknas');
  perform pg_temp.expect((select count(*) from cron.job where jobname like 'slowlane-%' and active) = 3, 'fel antal aktiva Slowlane-jobb');

  select s.decrypted_secret into v_secret from vault.decrypted_secrets s where s.name = 'slowlane_push_hook';

  insert into auth.users (id, aud, role, email, is_anonymous) values
    (a, 'authenticated', 'authenticated', 'slowlane-ltest-a@example.invalid', false),
    (b, 'authenticated', 'authenticated', 'slowlane-ltest-b@example.invalid', false),
    (c, 'authenticated', 'authenticated', 'slowlane-ltest-c@example.invalid', false),
    (g, 'authenticated', 'authenticated', 'slowlane-ltest-g@example.invalid', false);
  insert into auth.identities (provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
  select 'slowlane-ltest-' || u, u, jsonb_build_object('sub', 'slowlane-ltest-' || u), 'google', now(), now(), now()
  from unnest(array[a, b, c, g]) u;
  insert into public.god_users (user_id) values (g);

  perform pg_temp.act(a);
  select x.id, x.code into v_gid, v_code from public.group_create('Gränstest', 'TestA') x;
  perform pg_temp.act(b); perform public.group_join(v_code, 'TestB');
  perform pg_temp.act(c); perform public.group_join(v_code, 'TestC');
  perform pg_temp.act(g); perform public.group_join(v_code, 'TestG');

  -- ---------- Högst 3 nya träffar i timmen per förare ----------
  perform pg_temp.act(b);
  -- felaktiga försök räknas inte
  begin perform public.meetup_create(v_gid, 'x', 55.6, 13.0, now() + interval '1 hour'); exception when sqlstate 'PT400' then null; end;
  begin perform public.meetup_create(v_gid, 'x', 55.6, 13.0, now() + interval '1 hour'); exception when sqlstate 'PT400' then null; end;
  v_m := public.meetup_create(v_gid, 'Ett', 55.6, 13.0, now() + interval '1 hour');
  perform public.meetup_create(v_gid, 'Två', 55.6, 13.0, now() + interval '2 hours');
  perform public.meetup_create(v_gid, 'Tre', 55.6, 13.0, now() + interval '3 hours');
  begin perform public.meetup_create(v_gid, 'Fyra', 55.6, 13.0, now() + interval '4 hours'); perform pg_temp.expect(false, 'fjärde träffen inom en timme gick'); exception when sqlstate 'PT429' then null; end;
  -- att radera en träff ger ingen ny plats
  perform public.meetup_delete(v_m);
  perform pg_temp.expect(exists (select 1 from public.meetup_log where meetup_id = v_m), 'loggen försvann när träffen raderades');
  begin perform public.meetup_create(v_gid, 'Fyra', 55.6, 13.0, now() + interval '4 hours'); perform pg_temp.expect(false, 'radera och skapa igen gick runt gränsen'); exception when sqlstate 'PT429' then null; end;
  -- en annan förare påverkas inte
  perform pg_temp.act(c); perform public.meetup_create(v_gid, 'Cs träff', 55.6, 13.0, now() + interval '5 hours');
  -- efter en timme går det igen
  update public.meetup_log set created_at = now() - interval '61 minutes' where creator = b;
  perform pg_temp.act(b); perform public.meetup_create(v_gid, 'Fyra', 55.6, 13.0, now() + interval '4 hours');

  -- ---------- Högst 10 per dygn ----------
  update public.meetup_log set created_at = now() - interval '2 hours' where creator = b;
  insert into public.meetup_log (meetup_id, group_id, creator, created_at)
  select gen_random_uuid(), v_gid, b, now() - interval '2 hours' from generate_series(1, 6);   -- totalt 10 senaste dygnet
  begin perform public.meetup_create(v_gid, 'Elva', 55.6, 13.0, now() + interval '6 hours'); perform pg_temp.expect(false, 'elfte träffen samma dygn gick'); exception when sqlstate 'PT429' then null; end;
  update public.meetup_log set created_at = now() - interval '25 hours' where creator = b;
  perform public.meetup_create(v_gid, 'Elva', 55.6, 13.0, now() + interval '6 hours');

  -- ---------- God mode har ingen gräns (egen grupp, så att gruppens 10 kommande inte tar slut) ----------
  perform pg_temp.act(a);
  select x.id, x.code into v_gid2, v_code from public.group_create('Gränstest 2', 'TestA') x;
  perform pg_temp.act(c); perform public.group_join(v_code, 'TestC');
  perform pg_temp.act(g); perform public.group_join(v_code, 'TestG');
  perform pg_temp.act(c); perform public.push_save('https://fcm.googleapis.com/fcm/send/ltest-c', k, au);
  perform pg_temp.act(g);
  for i in 1..7 loop
    v_ids := v_ids || public.meetup_create(v_gid2, 'God ' || i, 55.6, 13.0, now() + make_interval(hours => i), true);
  end loop;
  perform pg_temp.expect(array_length(v_ids, 1) = 7, 'God mode fick inte skapa 7 träffar i rad');

  -- ---------- Högst 5 notiser per grupp och timme ----------
  for i in 1..5 loop
    select count(*) into v_n from public.push_job(v_ids[i], v_secret);
    perform pg_temp.expect(v_n = 1, 'notis ' || i || ' gick inte iväg (fick ' || v_n || ' mottagare)');
  end loop;
  select count(*) into v_n from public.push_job(v_ids[6], v_secret);
  perform pg_temp.expect(v_n = 0, 'sjätte notisen samma timme gick iväg');
  perform pg_temp.expect((select notified_at from public.meetups where id = v_ids[6]) is not null, 'sjätte träffen markerades inte, och kan få notis senare');
  perform pg_temp.expect((select count(*) from public.meetup_log where group_id = v_gid2 and notified_at is not null) = 5, 'loggen visar inte 5 notiser');
  perform pg_temp.expect(exists (select 1 from public.meetups where id = v_ids[6]), 'träffen utan notis finns inte i listan');
  -- andra grupper påverkas inte
  perform pg_temp.act(b); v_m := public.meetup_create(v_gid, 'Annan grupp', 55.6, 13.0, now() + interval '7 hours');
  select count(*) into v_n from public.push_job(v_m, v_secret);
  perform pg_temp.expect(v_n = 1, 'gränsen i en grupp stoppade notis i en annan grupp');
  -- efter en timme går det igen
  update public.meetup_log set notified_at = now() - interval '61 minutes' where group_id = v_gid2;
  select count(*) into v_n from public.push_job(v_ids[7], v_secret);
  perform pg_temp.expect(v_n = 1, 'notis gick inte iväg en timme senare');

  -- ---------- Städning ----------
  -- positioner: äldre än 4 minuter tas bort varje minut
  insert into public.riders (id, nick, vehicle, pos, updated_at) values
    (b, 'TestB', 'epa', st_setsrid(st_makepoint(13.0, 55.6), 4326)::geography, now() - interval '5 minutes'),
    (c, 'TestC', 'epa', st_setsrid(st_makepoint(13.0, 55.6), 4326)::geography, now() - interval '3 minutes');
  perform public.cleanup_live();
  perform pg_temp.expect(not exists (select 1 from public.riders where id = b), 'position som är 5 minuter gammal finns kvar');
  perform pg_temp.expect(exists (select 1 from public.riders where id = c), 'position som är 3 minuter gammal togs bort');
  -- loggen tas bort efter ett dygn
  update public.meetup_log set created_at = now() - interval '25 hours' where group_id = v_gid2 and meetup_id = v_ids[1];
  perform public.cleanup_riders();
  perform pg_temp.expect(not exists (select 1 from public.meetup_log where meetup_id = v_ids[1]), 'loggen finns kvar efter ett dygn');
  perform pg_temp.expect(exists (select 1 from public.meetup_log where meetup_id = v_ids[2]), 'städningen tog bort ny logg');
  -- försvinner med kontot och med gruppen
  perform pg_temp.act(b); perform public.delete_me();
  perform pg_temp.expect(not exists (select 1 from public.meetup_log where creator = b), 'loggen finns kvar efter radering av kontot');
  perform pg_temp.act(a); perform public.group_leave(v_gid2);
  perform pg_temp.expect(not exists (select 1 from public.meetup_log where group_id = v_gid2), 'loggen finns kvar när gruppen är borta');

  raise exception 'ALLA GRÄNSTESTER OK (allt är tillbakarullat)';
end
$$;
