import Link from "next/link";
import { notFound } from "next/navigation";
import { ContentEditor, RecommendationEditor } from "@/components/content-editors";
import { SyncRefresh } from "@/components/sync-refresh";
import { ApiError } from "@/lib/api";
import { getDataMode } from "@/lib/config";
import { toContentDraft } from "@/lib/content-edit";
import { analysisStatusLabels, coverageLabels, inputTypeLabels, notificationLabels, recommendationKindLabels, workflowStatusLabels } from "@/lib/labels";
import { createServerContentApi } from "@/lib/server-api";
import { saveContent, saveRecommendation } from "./actions";

function SourceLink({ url }: { url: string }) {
  try {
    const parsed = new URL(url);
    if (parsed.protocol === "http:" || parsed.protocol === "https:") {
      return <a href={parsed.href} rel="noreferrer" className="break-all underline">{url}</a>;
    }
  } catch {
    // The original value remains visible even if it cannot safely be opened.
  }
  return <span className="break-all">{url}</span>;
}

const sectionClass = "space-y-3 rounded-xl border border-border bg-background p-5 sm:p-6";

export default async function ContentDetails({ params }: { params: Promise<{ id: string }> }) {
  const { id } = await params;
  if (!/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(id)) notFound();
  const api = await createServerContentApi();
  const content = await api.getContent(id).catch((error: unknown) => {
    if (error instanceof ApiError && error.status === 404) notFound();
    throw error;
  });
  const live = getDataMode() === "api";

  return <article className="space-y-5">
    <Link href="/" prefetch={false} className="text-sm font-medium underline">← 보관함</Link>
    <header>
      <p className="text-sm font-medium text-primary">{inputTypeLabels[content.input_type]}</p>
      <h1 className="mt-2 break-words text-3xl font-semibold tracking-tight">{content.title || "제목 없는 콘텐츠"}</h1>
      <dl className="mt-4 flex flex-wrap gap-x-6 gap-y-2 text-sm">
        <div><dt className="inline font-medium">분석 </dt><dd className="inline">{analysisStatusLabels[content.analysis_status]}</dd></div>
        <div><dt className="inline font-medium">보관 </dt><dd className="inline">{workflowStatusLabels[content.workflow_status]}</dd></div>
        <div><dt className="inline font-medium">알림 </dt><dd className="inline">{notificationLabels[content.notification.visibility]}</dd></div>
      </dl>
      {live && <SyncRefresh key={content.id} snapshot={crypto.randomUUID()} contentId={content.id} />}
    </header>
    <section className={sectionClass}>
      <h2 className="text-lg font-semibold">원본</h2>
      {content.source_url && <SourceLink url={content.source_url} />}
      {content.source_text && <p className="whitespace-pre-wrap break-words">{content.source_text}</p>}
      {content.asset_ids.length > 0 && <p className="text-sm">첨부 파일 {content.asset_ids.length}개</p>}
    </section>
    <section className={sectionClass}>
      <h2 className="text-lg font-semibold">AI 요약</h2>
      <p className="whitespace-pre-wrap break-words">{content.analysis?.summary ?? (content.analysis || content.analysis_status === "failed" ? "확인 가능한 요약이 없어요." : "아직 분석 결과가 없어요.")}</p>
      {content.analysis && <p className="text-sm">분석 범위 · {coverageLabels[content.analysis.coverage]}</p>}
      {!!content.analysis?.limitations.length && <ul className="list-disc space-y-1 pl-5 text-sm">
        {content.analysis.limitations.map((limitation, index) => <li key={index}>{limitation}</li>)}
      </ul>}
    </section>
    <section className={sectionClass}>
      <h2 className="text-lg font-semibold">추천</h2>
      {content.recommendations.length === 0 ? <p className="text-sm">표시할 추천이 없어요.</p> : <ul className="space-y-4">
        {content.recommendations.map((recommendation) => <li key={recommendation.id} className="space-y-3 rounded-md border border-border p-4">
          <p className="text-sm font-semibold text-primary">{recommendationKindLabels[recommendation.kind]} · {recommendation.accepted ? "수락됨" : "AI가 생성한 추천"}</p>
          <p className="whitespace-pre-wrap break-words">{recommendation.text}</p>
          {recommendation.source_url && <SourceLink url={recommendation.source_url} />}
          {recommendation.user_text && <div className="rounded-md bg-muted p-3 text-sm">
            <h3 className="font-semibold">내가 수정한 문구</h3>
            <p className="mt-1 whitespace-pre-wrap break-words">{recommendation.user_text}</p>
          </div>}
          {live && <RecommendationEditor
            id={recommendation.id}
            current={{ version: recommendation.version, user_text: recommendation.user_text ?? "" }}
            save={saveRecommendation.bind(null, content.id, recommendation.id)}
          />}
        </li>)}
      </ul>}
    </section>
    <section className={sectionClass}>
      <h2 className="text-lg font-semibold">내 메모와 보관 상태</h2>
      <p className="whitespace-pre-wrap break-words">{content.user_note || "작성한 메모가 없어요."}</p>
      {live ? <ContentEditor key={content.id} id={content.id} current={toContentDraft(content)} save={saveContent.bind(null, content.id)} />
        : <p className="text-sm">샘플 모드에서는 읽기만 할 수 있어요.</p>}
    </section>
  </article>;
}
