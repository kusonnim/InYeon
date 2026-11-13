# Real-account RLS probe

Run this probe after applying the repository migrations and preparing two
disposable, confirmed Supabase email/password accounts with synthetic rows.
It uses the Auth and PostgREST HTTP services directly so B's API can be developed
independently.

```powershell
python supabase/integration/verify_rls.py --config .cache/c1-rls.private.json
python -m unittest discover -s supabase/integration -p 'test_*.py'
```

Keep the config under an ignored directory such as `.cache/`. It contains
`url`, `publishable_key`, and exactly two `accounts`. Each account supplies
`id`, `email`, `password` and `fixtures`, a map from all eight owner-readable
table names to their seeded row objects. Optional `server_fixtures` holds rows
for the four server-only tables. Include only explicit fixture columns in each
row, with canonical values that PostgREST returns. Primary key columns and the
matching `user_id` are required. The same row is used as a valid insert payload
when testing that direct writes are denied.

The probe checks password sign-in and Auth identity, owner reads, hidden foreign
rows, anonymous denial, direct INSERT/PATCH/DELETE denial, server-only table
reads, and the four server-only RPC helpers. Every database denial must have
the expected HTTP status and PostgreSQL `42501` code. A missing route, a missing
fixture, and an unrelated error fail the check. Output uses account labels A/B
and table names, without passwords, tokens, keys, email addresses or response
bodies. A nonzero exit code indicates a failed check or blocked connection.

The negative write checks target only the supplied synthetic fixture rows. Use
disposable fixtures because an incorrectly permissive policy may allow a tested
write before the probe reports failure. This script does not provision or clean
up accounts, migrations, fixture data, or Storage objects.

The default requires HTTPS. `--allow-local` also permits HTTP loopback addresses
for a disposable local Supabase stack. Client keys may be modern publishable keys
or legacy anon JWT keys. Privileged keys are rejected.

The authorization model follows the [Supabase RLS guide](https://supabase.com/docs/guides/database/postgres/row-level-security).
