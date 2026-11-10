import { createServerClient } from "@supabase/ssr";
import { NextResponse, type NextRequest } from "next/server";
import { getDataMode, getSupabaseConfig, sessionCookieOptions } from "@/lib/config";

export async function proxy(request: NextRequest) {
  if (getDataMode() === "fixture") return NextResponse.next();

  const { url, key } = getSupabaseConfig();
  let response = NextResponse.next({ request });
  const supabase = createServerClient(url, key, {
    cookieOptions: sessionCookieOptions,
    cookies: {
      getAll: () => request.cookies.getAll(),
      setAll(cookiesToSet, headers) {
        for (const { name, value } of cookiesToSet) request.cookies.set(name, value);
        const next = NextResponse.next({ request });
        for (const cookie of response.cookies.getAll()) next.cookies.set(cookie);
        for (const { name, value, options } of cookiesToSet) {
          next.cookies.set(name, value, options);
        }
        for (const [name, value] of Object.entries(headers)) next.headers.set(name, value);
        response = next;
      },
    },
  });

  // Trigger verification/refresh so both this request and the browser see the latest token.
  await supabase.auth.getClaims();
  if (!response.headers.has("Cache-Control")) response.headers.set("Cache-Control", "private, no-store");
  return response;
}

export const config = {
  matcher: ["/((?!_next/static|_next/image|favicon.ico).*)"],
};
