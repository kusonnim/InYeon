import "server-only";

import { createServerClient } from "@supabase/ssr";
import { cookies } from "next/headers";
import { cache } from "react";
import { getDataMode, getSupabaseConfig, sessionCookieOptions } from "./config";

export async function createSupabaseSessionClient(writable: boolean) {
  const { url, key } = getSupabaseConfig();
  const cookieStore = await cookies();
  return createServerClient(url, key, {
    cookieOptions: sessionCookieOptions,
    cookies: {
      getAll: () => cookieStore.getAll(),
      setAll(cookiesToSet) {
        // The proxy persists any refresh for read-only Server Components.
        if (!writable) return;
        for (const { name, value, options } of cookiesToSet) {
          cookieStore.set(name, value, options);
        }
      },
    },
  });
}

export const getWebSession = cache(async () => {
  if (getDataMode() === "fixture") return null;
  const supabase = await createSupabaseSessionClient(false);
  // The session cookie supplies the raw bearer token, never a trusted user.
  const { data, error } = await supabase.auth.getSession();
  const accessToken = data.session?.access_token;
  if (error || !accessToken) return null;
  const verified = await supabase.auth.getClaims(accessToken);
  const claims = verified.data?.claims;
  if (verified.error || !claims?.sub) return null;
  return {
    accessToken,
    user: { id: claims.sub, email: typeof claims.email === "string" ? claims.email : undefined },
  };
});

export async function getWebSessionUser() {
  return (await getWebSession())?.user ?? null;
}
