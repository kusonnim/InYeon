# ITDA web — Developer C

This is a Next.js App Router foundation with TypeScript, Tailwind CSS and a local shadcn/ui-style Button primitive plus CLI configuration. Read the root `AGENTS.md`, `docs/PRODUCT.md`, `docs/OWNERSHIP.md` and `contracts/openapi.yaml` first.

## Run

Use current Node.js 22 LTS (22.6 or later) or Node.js 24 LTS. From `apps/web`:

```sh
npm ci
npm run dev
```

Open `http://localhost:3000`. The default `ITDA_DATA_MODE=fixture` reads the shared synthetic `contracts/examples/catalog.json`; no backend or AI service is needed. Copy `.env.example` to `.env.local` only if overriding defaults. The library and detail routes render original source, AI interpretation, user edits, coverage and independent workflow/notification state. Editing is visibly disabled; no browser system notifications are requested.

```sh
npm run typecheck
npm test
npm run build
```

## Replace fixtures safely

`src/lib/api.ts` defines the replaceable `ContentApi` and HTTP adapter. Supply a short-lived Supabase user-session token to `HttpContentApi`; never use a service-role key or commit tokens. `server-api.ts` intentionally rejects any mode other than `fixture` until authenticated session handling is implemented. The fixture adapter is isolated, in-memory and resets per instance; its edits are developer simulations and are not synchronized or durable.

`src/lib/types.ts` mirrors the authoritative OpenAPI contract, not a separately owned schema. A shared change must update the contract, database, both clients, fixtures and tests. Preserve `expected_version` and handle HTTP 409 by reloading and letting the user reconcile edits. Keep source text, generated analysis and user notes separate. Generated recommendations are not accepted feedback.

Next work: Supabase session integration, paginated library, version-aware editing, sync cursor persistence and two-user ownership integration checks. Deployment to Vercel and production auth are planned. Run Vercel builds with this monorepo's parent source files available because fixtures currently live outside the app directory.

Official setup references: [Next.js installation](https://nextjs.org/docs/app/getting-started/installation) and [shadcn/ui manual installation](https://ui.shadcn.com/docs/installation/manual).

Scripts explicitly use webpack. Next.js 16.4.5 Turbopack failed to start its CSS worker on the Windows authoring host; the webpack production path is verified separately. Reconsider Turbopack only after reproducing the same checks. This does not change the application contract.
