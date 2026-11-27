-- Testar God mode med tre påhittade Google-konton.
-- Allt rullas tillbaka: databasen ser likadan ut efteråt.
-- Förväntat svar: ett "fel" med texten ALLA GOD MODE-TESTER OK. Står det FEL: ... är något trasigt.

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
  a uuid := gen_random_uuid();   -- har God mode och skapar gruppen
  b uuid := gen_random_uuid();   -- vanlig medlem
  c uuid := gen_random_uuid();   -- inte med i gruppen
  v_gid uuid; v_code text; v_m uuid; v_n uuid;
begin
  -- Rättigheter
  perform pg_temp.expect(has_function_privilege('authenticated', 'public.god_me()', 'execute'), 'inloggade kan inte fråga om God mode');
  perform pg_temp.expect(not has_function_privilege('anon', 'public.god_me()', 'execute'), 'utan konto kan man fråga om God mode');
  perform pg_temp.expect(has_function_privilege('authenticated', 'public.meetup_create(uuid,text,double precision,double precision,timestamptz,boolean)', 'execute'), 'inloggade kan inte skapa träffar');
  perform pg_temp.expect(to_regprocedure('public.meetup_create(uuid,text,double precision,double precision,timestamptz)') is null, 'gamla meetup_create finns kvar');
  perform pg_temp.expect(not has_table_privilege('authenticated', 'public.god_users', 'select'), 'appen kan läsa god_users');

  insert into auth.users (id, aud, role, email, is_anonymous) values
    (a, 'authenticated', 'authenticated', 'slowlane-gtest-a@example.invalid', false),
    (b, 'authenticated', 'authenticated', 'slowlane-gtest-b@example.invalid', false),
    (c, 'authenticated', 'authenticated', 'slowlane-gtest-c@example.invalid', false);
  insert into auth.identities (provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
  select 'slowlane-gtest-' || u, u, jsonb_build_object('sub', 'slowlane-gtest-' || u), 'google', now(), now(), now()
  from unnest(array[a, b, c]) u;
  insert into public.god_users (user_id) values (a);

  perform pg_temp.act(a);
  perform pg_temp.expect(public.god_me(), 'A har inte God mode');
  select x.id, x.code into v_gid, v_code from public.group_create('Bilträffen', 'TestA') x;
  perform pg_temp.act(b); perform public.group_join(v_code, 'TestB');
  perform pg_temp.expect(not public.god_me(), 'B har God mode');

  -- Bara den med God mode får skapa en sådan träff
  begin perform public.meetup_create(v_gid, 'Fusk', 55.6, 13.0, now() + interval '1 hour', true); perform pg_temp.expect(false, 'B skapade en God mode-träff'); exception when sqlstate 'PT403' then null; end;
  v_n := public.meetup_create(v_gid, 'Vanlig', 55.6, 13.0, now() + interval '2 hours');            -- som äldre appar: utan p_god
  perform pg_temp.act(a);
  v_m := public.meetup_create(v_gid, 'Långfärd', 59.33, 18.07, now() + interval '3 hours', true);

  -- Alla i gruppen ser vilken träff som är God mode
  perform pg_temp.act(b);
  perform pg_temp.expect((select string_agg(x.title || ':' || x.god, ',' order by x.starts_at) from public.meetup_list() x) = 'Vanlig:false,Långfärd:true', 'listan visar inte God mode rätt');
  perform pg_temp.expect((select x.coming from public.meetup_list() x where x.id = v_m) = 1, 'skaparen räknas inte som kommer');
  perform pg_temp.act(c);
  perform pg_temp.expect((select count(*) from public.meetup_list()) = 0, 'icke-medlem ser träffarna');

  -- Raderas kontot försvinner God mode-rätten
  perform pg_temp.act(a); perform public.delete_me();
  perform pg_temp.expect(not exists (select 1 from public.god_users where user_id = a), 'god_users finns kvar efter radering');

  raise exception 'ALLA GOD MODE-TESTER OK (allt är tillbakarullat)';
end
$$;
