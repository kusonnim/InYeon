import type { Metadata } from "next";
import Link from "next/link";
import "./globals.css";

export const metadata: Metadata = { title: "ITDA — Development Library", description: "Connect what you save with what comes next." };

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return <html lang="en"><body>
    <header className="border-b border-border px-6 py-5"><nav className="mx-auto max-w-4xl"><Link href="/" className="text-xl font-bold">ITDA</Link><span className="ml-4 text-sm">Connect what you save with what comes next.</span></nav></header>
    <main className="mx-auto max-w-4xl px-6 py-8">
      <p role="status" className="mb-6 rounded border border-border bg-muted p-3 text-sm">Phase 0 fixture preview. All content is synthetic; authentication, synchronization, and persistent editing are planned.</p>
      {children}
    </main>
  </body></html>;
}
