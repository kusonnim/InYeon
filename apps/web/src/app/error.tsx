"use client";

import Link from "next/link";
import { Button } from "@/components/ui/button";

export default function PageError({ retry }: { retry: () => void }) {
  return <section role="alert" className="rounded-2xl border border-border bg-surface p-6">
    <h1 className="text-xl font-semibold">콘텐츠를 불러오지 못했어요</h1>
    <p className="mt-2 text-sm text-subtle">잠시 후 다시 시도해 주세요.</p>
    <div className="mt-4 flex flex-wrap items-center gap-4">
      <Button type="button" onClick={retry}>다시 시도</Button>
      <Link href="/" className="text-sm font-medium text-primary underline">보관함으로 돌아가기</Link>
    </div>
  </section>;
}
