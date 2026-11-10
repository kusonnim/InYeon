"use server";

import { ApiError } from "@/lib/api";
import { getDataMode } from "@/lib/config";
import { createServerContentApi } from "@/lib/server-api";
import { summarizeSyncPage, type SyncCheck } from "@/lib/sync";

export async function checkForChanges(cursor: string | null, sequence: string | null, contentId?: string): Promise<SyncCheck> {
  if (getDataMode() !== "api") return { kind: "unavailable" };
  const api = await createServerContentApi();
  try {
    const page = await api.syncChanges(cursor ?? undefined);
    return summarizeSyncPage(page, sequence, contentId);
  } catch (error) {
    if (cursor && error instanceof ApiError && error.status === 400 && error.body.error.code === "invalid_cursor") {
      return { kind: "reset" };
    }
    return { kind: "unavailable" };
  }
}
