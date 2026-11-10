"use client";

import Link from "next/link";
import { useState } from "react";
import { Button } from "@/components/ui/button";
import { analysisStatusLabels, inputTypeLabels, notificationLabels, workflowStatusLabels } from "@/lib/labels";
import type { Content } from "@/lib/types";

interface LibraryItem extends Pick<Content, "id" | "input_type" | "analysis_status" | "workflow_status"> {
  title: string;
  summary: string | null;
  hasAnalysis: boolean;
  notificationVisibility: Content["notification"]["visibility"];
  recommendationCount: number;
  createdAt: string;
  displayDate: string;
}

function normalize(text: string) {
  return text.normalize("NFKC").toLocaleLowerCase("ko-KR");
}

export function LibraryContents({ items }: { items: LibraryItem[] }) {
  const [query, setQuery] = useState("");
  const terms = normalize(query).trim().split(/\s+/).filter(Boolean);
  const visible = terms.length ? items.filter(({ title, summary }) => {
    const searchable = normalize(`${title} ${summary ?? ""}`);
    return terms.every((term) => searchable.includes(term));
  }) : items;

  if (!items.length) {
    return <section className="rounded-2xl border border-dashed border-border bg-surface px-5 py-12 text-center">
      <h2 className="text-lg font-semibold">표시할 콘텐츠가 없어요</h2>
      <p className="mt-2 text-sm text-subtle">Android 앱에서 콘텐츠를 공유하면 이 보관함에서 볼 수 있어요.</p>
    </section>;
  }

  return <section aria-label="저장한 콘텐츠">
    <div role="search" className="mb-6 rounded-2xl border border-border bg-surface p-4 sm:flex sm:items-end sm:justify-between sm:gap-5">
      <div className="min-w-0 sm:flex-1">
        <label htmlFor="library-search" className="text-sm font-semibold">현재 페이지 검색</label>
        <input
          id="library-search"
          type="search"
          value={query}
          onChange={(event) => setQuery(event.target.value)}
          maxLength={100}
          autoComplete="off"
          placeholder="제목 또는 AI 요약 검색"
          className="mt-2 w-full rounded-lg border border-border bg-background px-3 py-2.5 text-sm"
        />
      </div>
      <p role="status" className="mt-3 shrink-0 pb-2 text-sm tabular-nums text-subtle sm:mt-0">
        현재 페이지 {items.length}개 중 {visible.length}개 표시
      </p>
    </div>

    {visible.length ? <ul className="grid gap-4 sm:grid-cols-2">
      {visible.map((item) => <li key={item.id} className="flex min-w-0 flex-col rounded-2xl border border-border bg-surface p-5">
        <div className="flex items-center justify-between gap-3 text-xs font-medium text-subtle">
          <span className="rounded-md bg-muted px-2 py-1 font-semibold text-primary">{inputTypeLabels[item.input_type]}</span>
          <time dateTime={item.createdAt}>{item.displayDate}</time>
        </div>
        <h2 className="mt-4 break-words text-lg font-semibold leading-snug">
          <Link href={`/contents/${encodeURIComponent(item.id)}`} prefetch={false} className="hover:text-primary hover:underline">{item.title}</Link>
        </h2>
        <p className="mt-2 text-xs font-semibold text-primary">AI 요약</p>
        <p className="mt-1 line-clamp-3 break-words text-sm leading-relaxed text-subtle">
          {item.summary ?? (item.hasAnalysis ? "확인한 원본에서 요약을 만들 수 없었어요." : "아직 분석 결과가 없어요.")}
        </p>
        <div className="mt-auto pt-4">
          <dl className="flex flex-wrap items-center gap-x-4 gap-y-1 border-t border-border pt-3 text-xs">
            <div className="flex gap-1"><dt className="text-subtle">분석</dt><dd>{analysisStatusLabels[item.analysis_status]}</dd></div>
            <div className="flex gap-1"><dt className="text-subtle">진행</dt><dd>{workflowStatusLabels[item.workflow_status]}</dd></div>
            <div className="flex gap-1"><dt className="text-subtle">알림</dt><dd>{notificationLabels[item.notificationVisibility]}</dd></div>
            <div className="flex gap-1"><dt className="text-subtle">추천</dt><dd>{item.recommendationCount}개</dd></div>
          </dl>
        </div>
      </li>)}
    </ul> : <div className="rounded-2xl border border-dashed border-border bg-surface px-5 py-10 text-center">
      <p className="font-semibold">현재 페이지에 검색 결과가 없어요</p>
      <Button type="button" variant="outline" className="mt-4" onClick={() => setQuery("")}>검색어 지우기</Button>
    </div>}
  </section>;
}
