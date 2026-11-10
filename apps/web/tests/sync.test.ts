import assert from "node:assert/strict";
import test from "node:test";
import { summarizeSyncPage } from "../src/lib/sync.ts";
import type { SyncEvent } from "../src/lib/types.ts";

const event = {
  entity_type: "recommendation",
  entity_id: "recommendation",
  content_id: "parent",
  operation: "upsert",
  occurred_at: "2026-11-09T09:00:00Z",
} satisfies Omit<SyncEvent, "sequence">;

test("sync uses exact sequences, skips replay, and refreshes the recommendation's parent", () => {
  const events: SyncEvent[] = [
    { ...event, content_id: "other", sequence: "9007199254740992" },
    { ...event, sequence: "9007199254740993" },
    { ...event, content_id: null, entity_type: "preferences", sequence: "9007199254740994" },
  ];
  const page = { events, next_cursor: "opaque", has_more: true };
  const checkpoint = { kind: "page", cursor: "opaque", sequence: "9007199254740994", hasMore: true };
  assert.deepEqual(summarizeSyncPage(page, "9007199254740992", "parent"), { ...checkpoint, changed: true });
  assert.deepEqual(summarizeSyncPage(page, "9007199254740993", "parent"), { ...checkpoint, changed: false });
  assert.deepEqual(summarizeSyncPage(page, null, "unrelated"), { ...checkpoint, changed: false });
});

test("tombstones invalidate the current content view and library", () => {
  const page = { events: [{ ...event, operation: "delete" as const, sequence: "1" }], next_cursor: "next", has_more: false };
  const checkpoint = { kind: "page", cursor: "next", sequence: "1", hasMore: false, changed: true };
  assert.deepEqual(summarizeSyncPage(page, null, "parent"), checkpoint);
  assert.deepEqual(summarizeSyncPage(page, null), checkpoint);
});
