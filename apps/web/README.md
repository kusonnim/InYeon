# ITDA web — Developer C

The web library uses Next.js, TypeScript and Tailwind CSS. The shared behavior and wire format are in `docs/PRODUCT.md` and `contracts/openapi.yaml`.

## Run

Use current Node.js 22 LTS (22.6 or later) or Node.js 24 LTS. From `apps/web`:

```sh
npm ci
npm run dev
```

Open `http://localhost:3000`. The default `ITDA_DATA_MODE=fixture` renders the shared synthetic catalog in read-only preview. It runs without credentials or an API.

```sh
npm run typecheck
npm test
npm run build
```

## Connect Auth and FastAPI

1. Copy `.env.example` to `.env.local` and set `ITDA_DATA_MODE=api`.
2. Set `ITDA_API_BASE_URL` to B's FastAPI instance and provide `NEXT_PUBLIC_SUPABASE_URL` and `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` from the Supabase project shared with Android and FastAPI. The local stack also supports its legacy anon key. Keep service keys and user tokens out of this file.
3. Sign in with an existing email/password account in that Supabase project. The web server verifies the user session and sends the user JWT to FastAPI. B's authenticated data adapter must be available to use saved content.

Hosted sign-in requires HTTPS for the session cookies. Session refresh follows the [Supabase SSR guide for Next.js](https://supabase.com/docs/guides/auth/server-side/nextjs).

## Library behavior

- The library uses opaque API cursors. Search filters the current page's titles and AI summaries in the browser. The API contract would need a shared search operation to support server-side search across all pages.
- Edit the title, personal note, workflow state or a recommendation's user wording. A version conflict shows the latest server values and preserves the draft. Explicitly combine the changes and save again. The original source and generated text remain visible separately.
- Unsaved edits stay in account-scoped memory across page errors and retries. Saving, cancelling or changing accounts clears them. Reloading or closing the browser clears this temporary memory.
- FastAPI requests time out after 30 seconds so a stalled synchronization request can release the pending action queue.
- The active page checks `/v1/sync` every 15 seconds and when the tab becomes visible or reconnects. Relevant events refresh the server-rendered page. The cursor lives in the open tab and advances after that page renders. An expired cursor reloads the page and starts a new sync. Opening a page loads a fresh API snapshot.
- The detail view shows saved links, text and the attachment count. Opening private attachment files is outside this increment.

When B's real adapter is available, use two disposable test accounts to verify that each account sees only its own library and that Android and web updates propagate in both directions. See [integration checks](../../docs/INTEGRATION.md#end-to-end-acceptance-procedure-for-the-real-adapters).

The scripts use Webpack. Keep the monorepo parent source available for builds because the synthetic catalog lives in `contracts/examples/`.
