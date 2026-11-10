import Link from "next/link";

export default function NotFound() {
  return <section className="rounded-2xl border border-border bg-surface p-6">
    <h1 className="text-xl font-semibold">콘텐츠를 찾을 수 없어요</h1>
    <p className="mt-2 text-sm text-subtle">보관함에서 열 수 있는 콘텐츠를 확인하세요.</p>
    <Link href="/" className="mt-4 inline-block text-sm font-medium text-primary underline">보관함으로 돌아가기</Link>
  </section>;
}
