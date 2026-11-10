import Link from "next/link";
import { redirect } from "next/navigation";
import { Button } from "@/components/ui/button";
import { getDataMode } from "@/lib/config";
import { getWebSessionUser } from "@/lib/supabase-session";
import { signIn } from "./actions";

const inputClassName = "w-full rounded-md border border-border bg-background px-3 py-2.5 text-base";

export default async function LoginPage({ searchParams }: { searchParams: Promise<{ error?: string }> }) {
  if (getDataMode() !== "api") redirect("/");
  const { error } = await searchParams;
  const user = await getWebSessionUser();
  if (user && error !== "signout") redirect("/");

  return <section className="mx-auto mt-8 max-w-md rounded-2xl border border-border bg-white p-6 sm:p-8">
    <h1 className="text-2xl font-semibold">잇다에 로그인</h1>
    <p className="mt-2 text-sm">Android 앱에서 사용하는 잇다 계정으로 웹 보관함을 열 수 있어요.</p>
    {user ? (
      <div className="mt-6">
        <p role="alert" className="text-sm text-red-800">로그아웃에 실패했어요. 다시 시도해 주세요.</p>
        <Link href="/" className="mt-3 inline-block underline">보관함으로</Link>
      </div>
    ) : (
      <form action={signIn} className="mt-6 grid gap-4">
        {error === "credentials" && <p role="alert" className="text-sm text-red-800">로그인할 수 없어요. 이메일과 비밀번호를 확인해 주세요.</p>}
        <label className="grid gap-2 text-sm font-medium">
          이메일
          <input className={inputClassName} type="email" name="email" autoComplete="email" required />
        </label>
        <label className="grid gap-2 text-sm font-medium">
          비밀번호
          <input className={inputClassName} type="password" name="password" autoComplete="current-password" required />
        </label>
        <Button type="submit" className="mt-2 w-full">로그인</Button>
      </form>
    )}
  </section>;
}
