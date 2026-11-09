import Link from "next/link";
import { createServerContentApi } from "@/lib/server-api";

export default async function LibraryPage() {
  const { items } = await createServerContentApi().listContents();
  return <>
    <h1 className="text-2xl font-semibold">Saved content</h1>
    <p className="mt-2 text-sm">A factual summary can be useful on its own. Recommendations are optional.</p>
    <ul className="mt-6 grid gap-4">
      {items.map((content) => <li key={content.id} className="rounded border border-border p-4">
        <h2 className="font-semibold"><Link href={`/contents/${content.id}`} className="underline">{content.title ?? "Untitled content"}</Link></h2>
        <p className="mt-2">{content.analysis?.summary ?? (content.analysis ? "No grounded summary is available." : "Saved; analysis is not yet available.")}</p>
        <p className="mt-3 text-sm">Analysis: {content.analysis_status} · Workflow: {content.workflow_status} · Notification: {content.notification.visibility}</p>
      </li>)}
    </ul>
  </>;
}
