"use client";

import { useRouter } from "next/navigation";
import { useEffect, useRef, useState } from "react";
import { checkForChanges } from "@/app/sync-action";
import type { SyncCheck } from "@/lib/sync";

const pollIntervalMs = 15_000;
type Checkpoint = { cursor: string | null; sequence: string | null };
type RefreshPage = Extract<SyncCheck, { kind: "reset" | "page" }>;

/** This tab renders fresh server snapshots and keeps only its live sync position. */
export function SyncRefresh({ snapshot, contentId }: { snapshot: string; contentId?: string }) {
  const router = useRouter();
  const [delayed, setDelayed] = useState(false);
  const checkpoint = useRef<Checkpoint>({ cursor: null, sequence: null });
  const waiting = useRef<{ snapshot: string; page: RefreshPage } | null>(null);

  useEffect(() => {
    let active = true;
    let timer: ReturnType<typeof setTimeout>;
    let running = false;

    // Commit a cursor only after the server-rendered page incorporates its changes.
    if (waiting.current && waiting.current.snapshot !== snapshot) {
      const { page } = waiting.current;
      checkpoint.current = page.kind === "reset"
        ? { cursor: null, sequence: null }
        : { cursor: page.cursor, sequence: page.sequence };
      waiting.current = null;
    }

    function schedule(delay: number) {
      clearTimeout(timer);
      timer = setTimeout(poll, delay);
    }

    async function poll() {
      if (!active || running) return;
      if (document.visibilityState === "hidden") {
        schedule(pollIntervalMs);
        return;
      }
      running = true;
      try {
        if (waiting.current) {
          // A previous refresh can fail during a disconnect. Retry without skipping it.
          router.refresh();
          schedule(pollIntervalMs);
          return;
        }
        const { cursor, sequence } = checkpoint.current;
        const page = await checkForChanges(cursor, sequence, contentId);
        if (!active) return;
        setDelayed(page.kind === "unavailable");
        if (page.kind === "reset" || (page.kind === "page" && page.changed)) {
          waiting.current = { snapshot, page };
          router.refresh();
        } else if (page.kind === "page") {
          checkpoint.current = { cursor: page.cursor, sequence: page.sequence };
        }
        const advance = page.kind === "page" && page.hasMore && page.cursor !== cursor;
        schedule(advance && !waiting.current ? 0 : pollIntervalMs);
      } catch {
        if (!active) return;
        setDelayed(true);
        schedule(pollIntervalMs);
      } finally {
        running = false;
      }
    }

    function resume() {
      if (document.visibilityState === "visible") schedule(0);
    }

    schedule(0);
    document.addEventListener("visibilitychange", resume);
    window.addEventListener("online", resume);
    return () => {
      active = false;
      clearTimeout(timer);
      document.removeEventListener("visibilitychange", resume);
      window.removeEventListener("online", resume);
    };
  }, [contentId, router, snapshot]);

  return delayed ? <p role="status" className="mt-2 text-sm">동기화가 지연되고 있어요. 연결이 돌아오면 다시 확인합니다.</p> : null;
}
