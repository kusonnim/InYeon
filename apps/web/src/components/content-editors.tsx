"use client";

import { useActionState, useEffect, useState } from "react";
import { Button } from "@/components/ui/button";
import { useEditorDrafts, type ContentEditDraft, type RecommendationEditDraft } from "@/components/editor-drafts";
import { rebaseContentDraft, type EditResult, type VersionedContentDraft, type VersionedRecommendationDraft } from "@/lib/content-edit";
import { workflowStatusLabels } from "@/lib/labels";
import type { WorkflowStatus } from "@/lib/types";

type EditAction<T> = (previous: EditResult<T>, form: FormData) => Promise<EditResult<T>>;
const fieldClass = "mt-1 block w-full rounded-md border border-border bg-background px-3 py-2 text-sm";

function Saved({ close }: { close: () => void }) {
  return <div className="flex flex-wrap items-center gap-3">
    <p role="status" className="text-sm">저장했어요.</p>
    <Button type="button" variant="outline" size="sm" onClick={close}>닫기</Button>
  </div>;
}

export function ContentEditor({ id, current, save }: { id: string; current: VersionedContentDraft; save: EditAction<VersionedContentDraft> }) {
  const { contents, setContent } = useEditorDrafts();
  const [saved, setSaved] = useState(false);
  const draft = contents[id];
  if (saved) return <Saved close={() => setSaved(false)} />;
  return draft
    ? <ContentForm editing={draft} update={(next) => setContent(id, next)} save={save} close={() => setContent(id, null)} onSaved={() => {
      setContent(id, null);
      setSaved(true);
    }} />
    : <Button type="button" variant="outline" onClick={() => setContent(id, { base: current, values: current })}>제목·메모·상태 수정</Button>;
}

function ContentForm({ editing, update, save, close, onSaved }: {
  editing: ContentEditDraft; update: (next: ContentEditDraft) => void;
  save: EditAction<VersionedContentDraft>; close: () => void; onSaved: () => void;
}) {
  const { base, values: draft } = editing;
  const [result, submit, pending] = useActionState(save, { kind: "idle" });
  useEffect(() => {
    if (result.kind === "saved") onSaved();
  }, [result.kind, onSaved]);
  const conflict = result.kind === "conflict" && result.latest.version !== base.version ? result.latest : null;
  const titleChanged = draft.title !== base.title;
  const noteChanged = draft.user_note !== base.user_note;
  const workflowChanged = draft.workflow_status !== base.workflow_status;

  return <form action={submit} className="space-y-4">
    <fieldset disabled={pending} className="space-y-3">
      <input type="hidden" name="expected_version" value={base.version} />
      <label className="block text-sm font-medium">제목
        <input className={fieldClass} name={titleChanged ? "title" : undefined} value={draft.title} onChange={(event) => update({ base, values: { ...draft, title: event.target.value } })} />
      </label>
      <label className="block text-sm font-medium">내 메모
        <textarea className={fieldClass} name={noteChanged ? "user_note" : undefined} rows={3} value={draft.user_note} onChange={(event) => update({ base, values: { ...draft, user_note: event.target.value } })} />
      </label>
      <label className="block text-sm font-medium">보관 상태
        <select className={fieldClass} name={workflowChanged ? "workflow_status" : undefined} value={draft.workflow_status} onChange={(event) => update({ base, values: { ...draft, workflow_status: event.target.value as WorkflowStatus } })}>
          {Object.entries(workflowStatusLabels).map(([value, label]) => <option key={value} value={value}>{label}</option>)}
        </select>
      </label>
    </fieldset>
    {conflict && <div role="alert" className="space-y-2 rounded-md border border-border bg-muted p-3 text-sm">
      <p>다른 곳에서 이 항목이 수정됐어요. 입력한 내용은 그대로 두었어요.</p>
      <dl className="grid grid-cols-[max-content_1fr] gap-x-3 gap-y-1 break-words">
        <dt>현재 제목</dt><dd>{conflict.title || "없음"}</dd>
        <dt>현재 메모</dt><dd className="whitespace-pre-wrap">{conflict.user_note || "없음"}</dd>
        <dt>현재 상태</dt><dd>{workflowStatusLabels[conflict.workflow_status]}</dd>
      </dl>
      <Button type="button" variant="outline" size="sm" onClick={() => {
        update({ base: conflict, values: { version: conflict.version, ...rebaseContentDraft(base, draft, conflict) } });
      }}>최신 버전에 내 변경 합치기</Button>
    </div>}
    {result.kind === "error" && <p role="alert" className="text-sm">{result.message}</p>}
    <div className="flex gap-2">
      <Button type="submit" disabled={pending || !!conflict || !(titleChanged || noteChanged || workflowChanged)}>{pending ? "저장 중…" : "저장"}</Button>
      <Button type="button" variant="outline" disabled={pending} onClick={close}>취소</Button>
    </div>
  </form>;
}

export function RecommendationEditor({ id, current, save }: {
  id: string; current: VersionedRecommendationDraft; save: EditAction<VersionedRecommendationDraft>;
}) {
  const { recommendations, setRecommendation } = useEditorDrafts();
  const [saved, setSaved] = useState(false);
  const draft = recommendations[id];
  if (saved) return <Saved close={() => setSaved(false)} />;
  return draft
    ? <RecommendationForm editing={draft} update={(next) => setRecommendation(id, next)} save={save} close={() => setRecommendation(id, null)} onSaved={() => {
      setRecommendation(id, null);
      setSaved(true);
    }} />
    : <Button type="button" size="sm" variant="outline" onClick={() => setRecommendation(id, { base: current, value: current.user_text })}>추천 문구 수정</Button>;
}

function RecommendationForm({ editing, update, save, close, onSaved }: {
  editing: RecommendationEditDraft; update: (next: RecommendationEditDraft) => void;
  save: EditAction<VersionedRecommendationDraft>; close: () => void; onSaved: () => void;
}) {
  const { base, value: draft } = editing;
  const [result, submit, pending] = useActionState(save, { kind: "idle" });
  useEffect(() => {
    if (result.kind === "saved") onSaved();
  }, [result.kind, onSaved]);
  const conflict = result.kind === "conflict" && result.latest.version !== base.version ? result.latest : null;

  return <form action={submit} className="space-y-3">
    <input type="hidden" name="expected_version" value={base.version} />
    <label className="block text-sm font-medium">내 추천 문구
      <textarea name="user_text" className={fieldClass} rows={3} value={draft} readOnly={pending} onChange={(event) => update({ base, value: event.target.value })} />
    </label>
    {conflict && <div role="alert" className="space-y-2 rounded-md border border-border bg-muted p-3 text-sm">
      <p>다른 곳에서 이 추천이 수정됐어요. 입력한 내용은 그대로 두었어요.</p>
      <p className="whitespace-pre-wrap break-words">현재 문구 · {conflict.user_text || "없음"}</p>
      <Button type="button" size="sm" variant="outline" onClick={() => update({ base: conflict, value: draft })}>최신 버전에서 내 문구 유지</Button>
    </div>}
    {result.kind === "error" && <p role="alert" className="text-sm">{result.message}</p>}
    <div className="flex gap-2">
      <Button type="submit" disabled={pending || !!conflict || draft === base.user_text}>{pending ? "저장 중…" : "저장"}</Button>
      <Button type="button" variant="outline" disabled={pending} onClick={close}>취소</Button>
    </div>
  </form>;
}
