import type { SyncPage } from "./types.ts";

export type SyncCheck =
  | { kind: "page"; cursor: string; sequence: string | null; changed: boolean; hasMore: boolean }
  | { kind: "reset" }
  | { kind: "unavailable" };

/** Consume sequence strings exactly, even when they exceed Number.MAX_SAFE_INTEGER. */
export function summarizeSyncPage(page: SyncPage, sequence: string | null, contentId?: string): SyncCheck {
  let lastSequence = sequence;
  let changed = false;
  for (const event of page.events) {
    if (lastSequence !== null && BigInt(event.sequence) <= BigInt(lastSequence)) continue;
    lastSequence = event.sequence;
    if (event.content_id !== null && (contentId === undefined || event.content_id === contentId)) changed = true;
  }
  return { kind: "page", cursor: page.next_cursor, sequence: lastSequence, changed, hasMore: page.has_more };
}
