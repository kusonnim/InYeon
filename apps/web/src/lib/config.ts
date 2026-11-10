import "server-only";

export const sessionCookieOptions = {
  httpOnly: true,
  secure: process.env.NODE_ENV === "production",
  sameSite: "lax",
} as const;

export function getDataMode(): "fixture" | "api" {
  const mode = process.env.ITDA_DATA_MODE ?? "fixture";
  if (mode === "fixture" || mode === "api") return mode;
  throw new Error("ITDA_DATA_MODE must be fixture or api.");
}

function getServiceUrl(value: string | undefined, name: string) {
  let url: URL;
  try {
    url = new URL(value ?? "");
  } catch {
    throw new Error(`${name} must be an absolute URL.`);
  }
  const loopback = ["localhost", "127.0.0.1", "[::1]"].includes(url.hostname);
  if ((url.protocol !== "https:" && !(loopback && url.protocol === "http:"))
    || url.username || url.password || url.search || url.hash) {
    throw new Error(`${name} must be an HTTPS URL or a local HTTP URL.`);
  }
  return url.href.replace(/\/$/, "");
}

function isPublicSupabaseKey(key: string): boolean {
  if (key.startsWith("sb_publishable_")) return true;
  try {
    const parts = key.split(".");
    if (parts.length !== 3) return false;
    const claims = JSON.parse(Buffer.from(parts[1], "base64url").toString("utf8"));
    return claims?.role === "anon";
  } catch {
    return false;
  }
}

export function getSupabaseConfig() {
  const url = getServiceUrl(process.env.NEXT_PUBLIC_SUPABASE_URL, "NEXT_PUBLIC_SUPABASE_URL");
  const key = process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY ?? "";
  if (!isPublicSupabaseKey(key)) {
    throw new Error("Set NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY to a publishable or legacy anon key.");
  }
  return { url, key };
}

export function getBackendUrl(): string {
  return getServiceUrl(process.env.ITDA_API_BASE_URL, "ITDA_API_BASE_URL");
}
