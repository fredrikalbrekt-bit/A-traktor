# Tester

Testerna körs lokalt. Mappen publiceras inte på sidan (se `_config.yml`).

## Service worker och notisfunktionen (Node)

```
node --test tests/
```

- `sw-cache.test.mjs`: vad installationen hämtar, bilder, gröna vägar och vad en ny version behåller.
- `sw-timeout.test.mjs`: den sparade appen visas efter 3 s när nätet är långsamt.
- `push-handler.test.mjs`: notisfunktionen i `supabase/functions/meetup-push` med låtsad Deno, Supabase och notistjänster.
  Testet gör ett eget nyckelpar, så den riktiga VAPID-nyckeln behövs inte. Den finns bara i Supabase.

## Appen i webbläsaren

```
node tests/serve.mjs
```

Öppna sedan <http://localhost:5173/tests/run.html>. Varje test startar appen på nytt med `tests/stub.js`,
som låtsas vara Supabase, Stadia Maps, GPS och skärmlåset. Sidans titel blir `OK n/n` eller `FEL x av n`.
Kartbiblioteket hämtas från nätet. Utan nät fungerar testerna, men kartorna syns inte.

Appen med låtsade tjänster går också att prova för hand: <http://localhost:5173/index.html?test=1>.

## Databasen (Supabase)

Filerna i `tests/sql` körs i Supabase SQL Editor, en i taget, efter att `supabase/live-riders.sql` är körd.
De skapar påhittade konton och rullar tillbaka allt. Svaret ska vara ett "fel" som slutar med `OK`,
till exempel `ALLA NOTISTESTER OK`. Står det `FEL: …` är något trasigt.
`push.sql` och `limits.sql` behöver hemligheten `slowlane_push_hook` i Vault.
