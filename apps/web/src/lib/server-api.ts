import "server-only";

import { redirect } from "next/navigation";
import { HttpContentApi, type ContentApi } from "./api";
import { getBackendUrl, getDataMode } from "./config";
import { FixtureContentApi } from "./fixture-api";
import { getWebSession } from "./supabase-session";

export async function createServerContentApi(): Promise<ContentApi> {
  if (getDataMode() === "fixture") return new FixtureContentApi();
  const session = await getWebSession();
  if (!session) redirect("/login");
  return new HttpContentApi(getBackendUrl(), async () => session.accessToken);
}
