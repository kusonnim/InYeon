import type { Metadata } from "next";
import Link from "next/link";
import { Button } from "@/components/ui/button";
import { EditorDraftProvider } from "@/components/editor-drafts";
import { getDataMode } from "@/lib/config";
import { getWebSessionUser } from "@/lib/supabase-session";
import { signOut } from "./login/actions";
import "./globals.css";

export const metadata: Metadata = { title: "잇다 · ITDA", description: "모바일에서 저장한 콘텐츠를 웹 보관함에서 확인하세요." };
// A fixture-mode build can serve API mode at runtime. Auth pages must stay request-scoped.
export const dynamic = "force-dynamic";

export default async function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  const fixture = getDataMode() === "fixture";
  const user = fixture ? null : await getWebSessionUser();
  return <html lang="ko"><body>
    <header className="border-b border-border bg-white">
      <nav aria-label="주 메뉴" className="mx-auto flex max-w-6xl items-center justify-between gap-4 px-4 py-4 sm:px-6 lg:px-8">
        <Link href="/" className="shrink-0 text-xl font-bold tracking-tight">잇다 <span className="text-sm font-semibold text-primary">ITDA</span></Link>
        {user && <div className="flex min-w-0 items-center gap-3">
          {user.email && <span className="truncate text-sm">{user.email}</span>}
          <form action={signOut} className="shrink-0">
            <Button type="submit" variant="outline" size="sm">로그아웃</Button>
          </form>
        </div>}
      </nav>
    </header>
    <main className="mx-auto max-w-6xl px-4 py-8 sm:px-6 lg:px-8">
      {fixture && <p role="status" className="mb-6 rounded-lg border border-border bg-muted px-4 py-3 text-sm">미리보기 · 샘플 콘텐츠를 표시해요. 편집과 동기화는 API 모드에서 사용할 수 있어요.</p>}
      <EditorDraftProvider key={fixture ? "fixture" : user?.id ?? "signed-out"}>
        {children}
      </EditorDraftProvider>
    </main>
  </body></html>;
}
