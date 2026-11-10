import Link from "next/link";
import { redirect } from "next/navigation";
import { LibraryContents } from "@/components/library-contents";
import { SyncRefresh } from "@/components/sync-refresh";
import { ApiError } from "@/lib/api";
import { getDataMode } from "@/lib/config";
import { createServerContentApi } from "@/lib/server-api";

const dateFormatter = new Intl.DateTimeFormat("ko-KR", {
  dateStyle: "medium",
  timeZone: "Asia/Seoul",
});

export default async function LibraryPage({ searchParams }: {
  searchParams: Promise<{ cursor?: string | string[]; cursorReset?: string }>;
}) {
  const params = await searchParams;
  const cursor = typeof params.cursor === "string" ? params.cursor : undefined;
  const api = await createServerContentApi();
  const page = await api.listContents(cursor).catch((error: unknown) => {
    if (cursor && error instanceof ApiError && error.status === 400 && error.body.error.code === "invalid_cursor") {
      redirect("/?cursorReset=1");
    }
    throw error;
  });
  const items = page.items.map((content) => ({
    id: content.id,
    title: content.title?.trim() || "제목 없는 콘텐츠",
    input_type: content.input_type,
    analysis_status: content.analysis_status,
    workflow_status: content.workflow_status,
    summary: content.analysis?.summary ?? null,
    hasAnalysis: content.analysis !== null,
    notificationVisibility: content.notification.visibility,
    recommendationCount: content.recommendations.length,
    createdAt: content.created_at,
    displayDate: dateFormatter.format(new Date(content.created_at)),
  }));

  return <>
    <div className="mb-7 rounded-2xl border border-border bg-muted px-5 py-6 sm:px-7 sm:py-8">
      <p className="text-xs font-semibold text-primary">잇다 · 라이브러리</p>
      <h1 className="mt-2 text-3xl font-bold tracking-tight sm:text-4xl">콘텐츠 보관함</h1>
      <p className="mt-2 max-w-xl text-sm leading-relaxed text-subtle">공유해 둔 링크, 메모, 파일의 원본과 AI 요약, 추천을 확인하세요.</p>
      {getDataMode() === "api" && <SyncRefresh key={cursor ?? ""} snapshot={crypto.randomUUID()} />}
    </div>

    {params.cursorReset === "1" && <p role="status" className="mb-4 rounded-lg border border-border bg-surface p-3 text-sm">
      요청한 페이지를 다시 열 수 없어 첫 페이지를 불러왔어요.
    </p>}

    <LibraryContents items={items} />

    {(cursor || page.next_cursor) && <nav aria-label="보관함 페이지" className="mt-6 flex flex-wrap justify-between gap-3">
      {cursor && <Link href="/" prefetch={false} className="rounded-lg border border-border bg-surface px-4 py-2 text-sm font-medium hover:bg-muted">첫 페이지</Link>}
      {page.next_cursor && <Link
        href={`/?${new URLSearchParams({ cursor: page.next_cursor })}`}
        prefetch={false}
        className="ml-auto rounded-lg bg-primary px-4 py-2 text-sm font-medium text-primary-foreground hover:opacity-90"
      >다음 페이지 →</Link>}
    </nav>}
  </>;
}
