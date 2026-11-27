-- Testar Slowlanes notiser med fyra påhittade Google-konton och ett anonymt konto.
-- Allt rullas tillbaka: databasen ser likadan ut efteråt, och inga notiser skickas.
-- Förväntat svar: ett "fel" med texten ALLA NOTISTESTER OK. Står det FEL: ... är något trasigt.

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
  a uuid := gen_random_uuid();   -- skapar gruppen och träffen
  b uuid := gen_random_uuid();   -- medlem med notiser på två telefoner
  c uuid := gen_random_uuid();   -- medlem som har blockerat A
  e uuid := gen_random_uuid();   -- inte med i gruppen, har notiser
  d uuid := gen_random_uuid();   -- anonymt konto
  k text := repeat('k', 87);     -- lika lång som en riktig p256dh-nyckel
  au text := repeat('a', 22);    -- lika lång som en riktig auth-nyckel
  fcm text := 'https://fcm.googleapis.com/fcm/send/';
  apple text := 'https://web.push.apple.com/';
  v_secret text; v_gid uuid; v_code text; v_m uuid; v_m2 uuid; v_q integer; v_seen text;
begin
  -- Rättigheter
  perform pg_temp.expect(not has_function_privilege('anon', 'public.push_save(text,text,text,text)', 'execute'), 'utan konto kan man spara notisadress');
  perform pg_temp.expect(has_function_privilege('authenticated', 'public.push_save(text,text,text,text)', 'execute'), 'inloggade kan inte spara notisadress');
  perform pg_temp.expect(not has_function_privilege('authenticated', 'public.push_job(uuid,text)', 'execute'), 'appen kan anropa push_job');
  perform pg_temp.expect(has_function_privilege('anon', 'public.push_job(uuid,text)', 'execute'), 'notisfunktionen kan inte anropa push_job');
  perform pg_temp.expect(not has_function_privilege('anon', 'public.push_hook_ok(text)', 'execute'), 'man kan pröva hemligheten direkt');
  perform pg_temp.expect(exists (select 1 from pg_trigger where tgname = 'meetups_push'), 'triggern saknas');

  select s.decrypted_secret into v_secret from vault.decrypted_secrets s where s.name = 'slowlane_push_hook';
  perform pg_temp.expect(char_length(v_secret) = 64, 'hemligheten saknas i Vault');

  insert into auth.users (id, aud, role, email, is_anonymous) values
    (a, 'authenticated', 'authenticated', 'slowlane-ptest-a@example.invalid', false),
    (b, 'authenticated', 'authenticated', 'slowlane-ptest-b@example.invalid', false),
    (c, 'authenticated', 'authenticated', 'slowlane-ptest-c@example.invalid', false),
    (e, 'authenticated', 'authenticated', 'slowlane-ptest-e@example.invalid', false),
    (d, 'authenticated', 'authenticated', null, true);
  insert into auth.identities (provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
  select 'slowlane-ptest-' || u, u, jsonb_build_object('sub', 'slowlane-ptest-' || u), 'google', now(), now(), now()
  from unnest(array[a, b, c, e]) u;

  -- Spara notisadresser
  perform pg_temp.act(d);
  begin perform public.push_save(fcm || 'd1', k, au); perform pg_temp.expect(false, 'anonymt konto sparade notisadress'); exception when sqlstate 'PT403' then null; end;
  perform pg_temp.act(b);
  begin perform public.push_save('https://evil.example/x', k, au); perform pg_temp.expect(false, 'okänd notistjänst gick'); exception when sqlstate 'PT400' then null; end;
  begin perform public.push_save('http://fcm.googleapis.com/fcm/send/x', k, au); perform pg_temp.expect(false, 'adress utan https gick'); exception when sqlstate 'PT400' then null; end;
  begin perform public.push_save(fcm || 'b1', 'kort', au); perform pg_temp.expect(false, 'för kort nyckel gick'); exception when sqlstate 'PT400' then null; end;
  perform public.push_save(fcm || 'b1', k, au, 'en');
  perform public.push_save(apple || 'b2', k, au, 'fransk');   -- okänt språk blir svenska
  perform public.push_save('https://wns2-db5p.notify.windows.com/w/?token=x', k, au);
  perform pg_temp.expect((select string_agg(lang, ',' order by endpoint) from public.push_subs where user_id = b) = 'en,sv,sv', 'språken sparades fel');
  perform public.push_delete('https://wns2-db5p.notify.windows.com/w/?token=x');
  perform pg_temp.expect((select count(*) from public.push_subs where user_id = b) = 2, 'push_delete tog inte bort');
  perform pg_temp.act(c); perform public.push_save(fcm || 'c1', k, au);
  perform pg_temp.act(e); perform public.push_save(fcm || 'e1', k, au);
  -- man kan inte ta bort någon annans adress
  perform public.push_delete(fcm || 'b1');
  perform pg_temp.expect(exists (select 1 from public.push_subs where endpoint = fcm || 'b1'), 'E tog bort B:s adress');

  -- Högst 10 telefoner per konto, den äldsta får ge plats
  perform pg_temp.act(e);
  update public.push_subs set saved_at = now() - interval '1 hour' where endpoint = fcm || 'e1';
  for i in 2..11 loop perform public.push_save(fcm || 'e' || i, k, au); end loop;
  perform pg_temp.expect((select count(*) from public.push_subs where user_id = e) = 10, 'E har inte 10 adresser');
  perform pg_temp.expect(not exists (select 1 from public.push_subs where endpoint = fcm || 'e1'), 'den äldsta adressen fick inte ge plats');

  -- Byter telefonen konto flyttas adressen
  perform pg_temp.act(a); perform public.push_save(fcm || 'e11', k, au);
  perform pg_temp.expect((select user_id from public.push_subs where endpoint = fcm || 'e11') = a, 'adressen flyttades inte till nya kontot');
  perform public.push_delete(fcm || 'e11');

  -- Grupp: A skapar, B och C går med. C har blockerat A.
  perform pg_temp.act(a);
  select x.id, x.code into v_gid, v_code from public.group_create('Notistest', 'TestA') x;
  perform pg_temp.act(b); perform public.group_join(v_code, 'TestB');
  perform pg_temp.act(c); perform public.group_join(v_code, 'TestC'); perform public.block_rider(a);

  -- En ny träff ber notisfunktionen att skicka (anropet ligger i kö tills allt rullas tillbaka)
  select count(*) into v_q from net.http_request_queue where url like '%/functions/v1/meetup-push';
  perform pg_temp.act(a);
  v_m := public.meetup_create(v_gid, 'Fika', 55.6, 13.0, now() + interval '2 hours');
  perform pg_temp.expect((select count(*) from net.http_request_queue where url like '%/functions/v1/meetup-push') = v_q + 1, 'ingen förfrågan till notisfunktionen');
  perform pg_temp.expect((select convert_from(q.body, 'utf8') from net.http_request_queue q where q.url like '%/functions/v1/meetup-push' order by q.id desc limit 1) like '%' || v_m || '%', 'förfrågan saknar träffens id');
  perform pg_temp.expect((select q.headers ->> 'x-slowlane-hook' from net.http_request_queue q where q.url like '%/functions/v1/meetup-push' order by q.id desc limit 1) = v_secret, 'förfrågan saknar hemligheten');
  perform pg_temp.expect((select q.headers ->> 'x-region' from net.http_request_queue q where q.url like '%/functions/v1/meetup-push' order by q.id desc limit 1) = 'eu-west-1', 'förfrågan körs inte i Irland');

  -- Mottagarna
  begin perform public.push_job(v_m, 'fel'); perform pg_temp.expect(false, 'fel hemlighet gick'); exception when sqlstate 'PT403' then null; end;
  begin perform public.push_job(v_m, null); perform pg_temp.expect(false, 'ingen hemlighet gick'); exception when sqlstate 'PT403' then null; end;
  select string_agg(x.endpoint || ':' || x.lang || ':' || x.title || ':' || x.group_name || ':' || x.creator_nick, ',' order by x.endpoint)
    into v_seen from public.push_job(v_m, v_secret) x;
  perform pg_temp.expect(v_seen = fcm || 'b1:en:Fika:Notistest:TestA,' || apple || 'b2:sv:Fika:Notistest:TestA',
    'bara B:s två telefoner ska få notis (inte A som skapade, inte C som blockerat A, inte E utanför gruppen), fick ' || coalesce(v_seen, 'ingen'));
  perform pg_temp.expect((select notified_at from public.meetups where id = v_m) is not null, 'träffen markerades inte');
  perform pg_temp.expect((select count(*) from public.push_job(v_m, v_secret)) = 0, 'samma träff gav notiser två gånger');

  -- En gammal träff som aldrig markerats ger inga notiser
  perform pg_temp.act(b);
  v_m2 := public.meetup_create(v_gid, 'Tur', 55.6, 13.0, now() + interval '1 day');
  update public.meetups set created_at = now() - interval '2 hours' where id = v_m2;
  perform pg_temp.expect((select count(*) from public.push_job(v_m2, v_secret)) = 0, 'gammal träff gav notiser');

  -- Ingen i gruppen vill ha notiser: ingen förfrågan
  perform pg_temp.act(b); perform public.push_delete(fcm || 'b1'); perform public.push_delete(apple || 'b2');
  perform pg_temp.act(c); perform public.push_delete(fcm || 'c1');
  select count(*) into v_q from net.http_request_queue where url like '%/functions/v1/meetup-push';
  perform pg_temp.act(a); perform public.meetup_create(v_gid, 'Utan notis', 55.6, 13.0, now() + interval '3 hours');
  perform pg_temp.expect((select count(*) from net.http_request_queue where url like '%/functions/v1/meetup-push') = v_q, 'förfrågan trots att ingen vill ha notiser');

  -- Adresser som inte finns längre tas bort
  begin perform public.push_gone(array[fcm || 'e2'], 'fel'); perform pg_temp.expect(false, 'push_gone med fel hemlighet gick'); exception when sqlstate 'PT403' then null; end;
  perform public.push_gone(array[fcm || 'e2', fcm || 'e3'], v_secret);
  perform pg_temp.expect((select count(*) from public.push_subs where user_id = e) = 7, 'push_gone tog inte bort');   -- e11 flyttade till A

  -- Städningen tar bort adresser som inte sparats på 90 dagar
  update public.push_subs set saved_at = now() - interval '91 days' where endpoint = fcm || 'e4';
  perform public.cleanup_riders();
  perform pg_temp.expect(not exists (select 1 from public.push_subs where endpoint = fcm || 'e4'), 'gammal adress togs inte bort');

  -- Radera kontot tar bort adresserna
  perform pg_temp.act(e); perform public.delete_me();
  perform pg_temp.expect(not exists (select 1 from public.push_subs where user_id = e), 'adresser finns kvar efter radering');

  raise exception 'ALLA NOTISTESTER OK (allt är tillbakarullat)';
end
$$;
