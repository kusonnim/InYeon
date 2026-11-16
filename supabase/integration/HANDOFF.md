# C1 shared Supabase environment

The shared integration project is `itda-integration` in Seoul (`ap-northeast-2`).
Its non-secret coordinates are in [project.json](project.json). A, B and C use
this project reference for Auth, PostgreSQL and Storage.

## Applied schema

The repository's two migrations applied successfully to hosted PostgreSQL 17.11.

| Version | Migration |
| --- | --- |
| 202611090001 | foundation |
| 202611090002 | notification_transitions |

The connector initially assigned deployment timestamps. The migration registry
was aligned to the existing repository versions after both applications succeeded,
so subsequent CLI migration checks use the same history.

The schema has 12 application tables with RLS, eight owner-read policies, and
four server-only tables. The `content-assets` bucket is private with a 20 MiB
limit. Security advisors reported four informational notices for the server-only
tables, which deliberately have no client policies or grants.

## Real account checks

Two confirmed email/password test accounts were provisioned as synthetic Auth
fixtures in this dedicated test project. Password hashes and email identities
were seeded administratively. Both accounts then signed in through the real
Supabase password endpoint and their issued tokens were checked through
`GET /auth/v1/user`.

The real HTTP RLS probe passed 86 grouped checks across the two accounts.
It verified owner reads, foreign-row hiding, anonymous denial, direct write
denial on all 12 tables, server-only reads, and all four privileged RPC helpers.
Synthetic records are retained for repeatable checks. They are test fixtures
seeded directly for authorization verification.

The eight verifier regression tests also passed.

## Connection handoff

The integration lead receives the publishable key and test credentials through
a separate private file. Keep that file outside tracked source. Existing I1
smoke commands use the same accounts through `ITDA_SMOKE_A_EMAIL`,
`ITDA_SMOKE_A_PASSWORD`, `ITDA_SMOKE_B_EMAIL`, and `ITDA_SMOKE_B_PASSWORD`.

| Component | Setting |
| --- | --- |
| B Auth verifier | Issuer and JWKS URL from project.json, audience `authenticated` |
| B PostgreSQL adapter | This project's connection details from Dashboard Connect, with TLS |
| Android staging | `ITDA_STAGING_SUPABASE_URL` and `ITDA_STAGING_SUPABASE_PUBLISHABLE_KEY` |
| I1 staging smoke | The same staging Auth variables and the two private test accounts |
| Web | `ITDA_DATA_MODE=api`, `NEXT_PUBLIC_SUPABASE_URL`, `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` |

B obtains server credentials and the database password through the project's
dashboard. Use the connection pooler offered by Dashboard Connect when the
deployment network requires IPv4. The API URL must be the same B deployment
in Android staging, I1's `ITDA_STAGING_API_BASE_URL`, and Web's
`ITDA_API_BASE_URL`.

## Remaining integration

B's authenticated persistent API is the next dependency for the shared
Android/Web run. Web session and transport support already exist.
Run the I1 staging preflight and smoke when that API is configured.

Private bucket configuration is verified. Actual private file bytes, owned
signed downloads and uploads still require the Storage integration check.
The full Android/Web acceptance run remains with the integration lead.
