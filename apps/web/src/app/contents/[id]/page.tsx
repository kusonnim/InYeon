import Link from "next/link";
import { notFound } from "next/navigation";
import { ApiError } from "@/lib/api";
import { createServerContentApi } from "@/lib/server-api";
import { Button } from "@/components/ui/button";

export default async function ContentDetails({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  const content = await createServerContentApi().getContent(id).catch((error: unknown) => {
    if (error instanceof ApiError && error.status === 404) notFound();
    throw error;
  });
  return <article>
    <Link href="/" className="text-sm underline">Back to library</Link>
    <h1 className="mt-4 text-2xl font-semibold">{content.title ?? "Untitled content"}</h1>
    <p className="mt-2 text-sm">Workflow: {content.workflow_status} · Version {content.version}</p>
    <section className="mt-6"><h2 className="font-semibold">Original source</h2>
      {content.source_url && <a href={content.source_url} rel="noreferrer" className="break-all underline">{content.source_url}</a>}
      {content.source_text && <p className="mt-2 whitespace-pre-wrap">{content.source_text}</p>}
    </section>
    <section className="mt-6"><h2 className="font-semibold">AI interpretation</h2>
      <p className="mt-2">{content.analysis?.summary ?? (content.analysis ? "No grounded summary is available." : "Analysis pending.")}</p>
      <p className="mt-2 text-sm">Coverage: {content.analysis?.coverage ?? "Not analyzed"}</p>
      {content.analysis?.limitations.map((limitation) => <p key={limitation} className="mt-1 text-sm">{limitation}</p>)}
    </section>
    <section className="mt-6"><h2 className="font-semibold">Recommendations</h2>
      {content.recommendations.length === 0 ? <p className="mt-2">No recommendation is appropriate for this content.</p> : <ul className="mt-2 space-y-3">{content.recommendations.map((recommendation) => <li key={recommendation.id}>
        <p><strong>{recommendation.kind}:</strong> {recommendation.text}</p>
        {recommendation.user_text && <p>User edit: {recommendation.user_text}</p>}
        <p className="text-sm">{recommendation.accepted ? "Explicitly accepted" : "Generated suggestion; not accepted"}</p>
      </li>)}</ul>}
    </section>
    <section className="mt-6"><h2 className="font-semibold">Your notes</h2><p className="mt-2">{content.user_note ?? "No notes yet."}</p></section>
    <p className="my-4 text-sm">Notification: {content.notification.visibility}. Dismissal does not change workflow status; dismissed items remain in this library.</p>
    <Button disabled title="Persistent editing is planned for the next phase">Edit (planned)</Button>
  </article>;
}
