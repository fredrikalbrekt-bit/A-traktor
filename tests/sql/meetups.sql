-- Testar Slowlanes träffar med fyra påhittade Google-konton.
-- Allt rullas tillbaka: databasen ser likadan ut efteråt.
-- Förväntat svar: ett "fel" med texten ALLA TRÄFFTESTER OK. Står det FEL: ... är något trasigt.

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
  a uuid := gen_random_uuid();   -- skapar gruppen
  b uuid := gen_random_uuid();   -- medlem som skapar träffar
  c uuid := gen_random_uuid();   -- inte med i gruppen, går med senare
  e uuid := gen_random_uuid();   -- medlem som tas bort
  v_gid uuid; v_code text; v_m1 uuid; v_m2 uuid;
begin
  -- Rättigheter
  perform pg_temp.expect(not has_function_privilege('authenticated', 'public.meetup_group(uuid,uuid)', 'execute'), 'appen kan anropa meetup_group');
  perform pg_temp.expect(not has_function_privilege('anon', 'public.meetup_list()', 'execute'), 'utan konto kan man lista träffar');
  perform pg_temp.expect(has_function_privilege('authenticated', 'public.meetup_create(uuid,text,double precision,double precision,timestamptz,boolean)', 'execute'), 'inloggade kan inte skapa träffar');

  insert into auth.users (id, aud, role, email, is_anonymous) values
    (a, 'authenticated', 'authenticated', 'slowlane-mtest-a@example.invalid', false),
    (b, 'authenticated', 'authenticated', 'slowlane-mtest-b@example.invalid', false),
    (c, 'authenticated', 'authenticated', 'slowlane-mtest-c@example.invalid', false),
    (e, 'authenticated', 'authenticated', 'slowlane-mtest-e@example.invalid', false);
  insert into auth.identities (provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
  select 'slowlane-mtest-' || u, u, jsonb_build_object('sub', 'slowlane-mtest-' || u), 'google', now(), now(), now()
  from unnest(array[a, b, c, e]) u;

  perform pg_temp.act(a);
  select x.id, x.code into v_gid, v_code from public.group_create('Träfftest', 'TestA') x;
  perform pg_temp.act(b); perform public.group_join(v_code, 'TestB');
  perform pg_temp.act(e); perform public.group_join(v_code, 'TestE');

  -- Skapa, och felaktiga träffar
  perform pg_temp.act(b);
  v_m1 := public.meetup_create(v_gid, 'Fika', 55.6, 13.0, now() + interval '2 hours');
  begin perform public.meetup_create(v_gid, 'x', 55.6, 13.0, now() + interval '1 hour'); perform pg_temp.expect(false, 'för kort titel gick'); exception when sqlstate 'PT400' then null; end;
  begin perform public.meetup_create(v_gid, 'Igår', 55.6, 13.0, now() - interval '1 hour'); perform pg_temp.expect(false, 'träff bakåt i tiden gick'); exception when sqlstate 'PT400' then null; end;
  begin perform public.meetup_create(v_gid, 'Långt fram', 55.6, 13.0, now() + interval '31 days'); perform pg_temp.expect(false, 'träff om 31 dagar gick'); exception when sqlstate 'PT400' then null; end;
  begin perform public.meetup_create(v_gid, 'Fel plats', 95, 13.0, now() + interval '1 hour'); perform pg_temp.expect(false, 'plats utanför jorden gick'); exception when sqlstate 'PT400' then null; end;
  perform pg_temp.act(c);
  begin perform public.meetup_create(v_gid, 'Utomstående', 55.6, 13.0, now() + interval '1 hour'); perform pg_temp.expect(false, 'icke-medlem skapade träff'); exception when sqlstate 'PT403' then null; end;

  -- Vem ser vad
  perform pg_temp.act(a);
  perform pg_temp.expect((select count(*) from public.meetup_list()) = 1, 'skaparen av gruppen ser inte träffen');
  perform pg_temp.expect((select x.can_delete from public.meetup_list() x), 'gruppens skapare kan inte ta bort');
  perform pg_temp.expect((select x.coming from public.meetup_list() x) = 1, 'den som skapade träffen räknas inte som kommer');
  perform pg_temp.expect((select x.my_answer from public.meetup_list() x) is null, 'A har ett svar utan att ha svarat');
  perform pg_temp.expect((select x.creator_nick from public.meetup_list() x) = 'TestB', 'fel namn på den som skapade');
  perform pg_temp.expect((select round(x.lat::numeric, 3) from public.meetup_list() x) = 55.6, 'fel plats');
  perform pg_temp.act(e);
  perform pg_temp.expect(not (select x.can_delete from public.meetup_list() x), 'vanlig medlem kan ta bort annans träff');
  perform pg_temp.act(c);
  perform pg_temp.expect((select count(*) from public.meetup_list()) = 0, 'icke-medlem ser träffen');
  begin perform public.meetup_answer(v_m1, true); perform pg_temp.expect(false, 'icke-medlem svarade'); exception when sqlstate 'PT403' then null; end;
  begin perform public.meetup_people(v_m1); perform pg_temp.expect(false, 'icke-medlem såg svaren'); exception when sqlstate 'PT403' then null; end;

  -- Svar
  perform pg_temp.act(a); perform public.meetup_answer(v_m1, true);
  perform pg_temp.act(e); perform public.meetup_answer(v_m1, true); perform public.meetup_answer(v_m1, false);   -- ångrade sig
  perform pg_temp.act(a);
  perform pg_temp.expect((select x.coming from public.meetup_list() x) = 2, 'två ska komma');
  perform pg_temp.expect((select x.my_answer from public.meetup_list() x), 'A:s svar sparades inte');
  perform pg_temp.expect((select string_agg(x.nick || ':' || x.coming, ',' order by x.nick) from public.meetup_people(v_m1) x) = 'TestA:true,TestB:true,TestE:false', 'svarslistan');

  -- Den som tas bort ur gruppen räknas inte och ser inte träffen
  perform pg_temp.act(e); perform public.meetup_answer(v_m1, true);
  perform pg_temp.act(a);
  perform pg_temp.expect((select x.coming from public.meetup_list() x) = 3, 'tre ska komma');
  perform public.group_kick(v_gid, e);
  perform pg_temp.expect((select x.coming from public.meetup_list() x) = 2, 'borttagen medlem räknas fortfarande');
  perform pg_temp.act(e);
  perform pg_temp.expect((select count(*) from public.meetup_list()) = 0, 'borttagen medlem ser träffen');

  -- Ta bort: inte en annans träff som vanlig medlem, men sin egen, och gruppens skapare får ta bort alla
  perform pg_temp.act(c); perform public.group_join(v_code, 'TestC');
  begin perform public.meetup_delete(v_m1); perform pg_temp.expect(false, 'medlem tog bort annans träff'); exception when sqlstate 'PT403' then null; end;
  perform pg_temp.act(b);
  v_m2 := public.meetup_create(v_gid, 'Tur', 55.7, 13.2, now() + interval '1 day');
  perform public.meetup_delete(v_m2);
  perform pg_temp.act(a);
  perform public.meetup_delete(v_m1);
  perform pg_temp.expect((select count(*) from public.meetup_list()) = 0, 'träffar finns kvar efter borttagning');
  begin perform public.meetup_delete(v_m1); perform pg_temp.expect(false, 'borttagen träff fanns kvar'); exception when sqlstate 'PT404' then null; end;

  -- Högst 10 kommande per grupp. En som är över sedan 3 timmar räknas inte.
  -- (gränsen på 3 nya träffar i timmen per förare testas i test-limits.sql, här flyttas loggen bakåt)
  perform pg_temp.act(b);
  for i in 1..10 loop
    update public.meetup_log set created_at = now() - interval '2 days' where creator = b;
    perform public.meetup_create(v_gid, 'Träff ' || i, 55.6, 13.0, now() + make_interval(hours => i));
  end loop;
  update public.meetup_log set created_at = now() - interval '2 days' where creator = b;
  begin perform public.meetup_create(v_gid, 'Träff 11', 55.6, 13.0, now() + interval '12 hours'); perform pg_temp.expect(false, 'elfte träffen gick'); exception when sqlstate 'PT409' then null; end;
  update public.meetups set starts_at = now() - interval '4 hours' where group_id = v_gid and title = 'Träff 1';
  perform pg_temp.act(a);
  perform pg_temp.expect((select count(*) from public.meetup_list()) = 9, 'träff som var över för 4 timmar sedan syns');
  perform pg_temp.act(b);
  perform public.meetup_create(v_gid, 'Träff 11', 55.6, 13.0, now() + interval '12 hours');

  -- Städningen raderar träffar ett dygn efter starten
  update public.meetups set starts_at = now() - interval '25 hours' where group_id = v_gid and title = 'Träff 1';
  perform public.cleanup_riders();
  perform pg_temp.expect(not exists (select 1 from public.meetups where group_id = v_gid and title = 'Träff 1'), 'gammal träff raderades inte');

  -- Tas gruppen bort försvinner träffarna
  perform pg_temp.act(a); perform public.group_leave(v_gid);
  perform pg_temp.expect(not exists (select 1 from public.meetups where group_id = v_gid), 'träffar finns kvar när gruppen är borta');

  raise exception 'ALLA TRÄFFTESTER OK (allt är tillbakarullat)';
end
$$;
