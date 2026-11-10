import type { Content, ContentPatch, RecommendationPatch, WorkflowStatus } from "./types.ts";

export interface ContentDraft {
  title: string;
  user_note: string;
  workflow_status: WorkflowStatus;
}

export type VersionedContentDraft = ContentDraft & { version: number };
export type VersionedRecommendationDraft = { user_text: string; version: number };
export type EditResult<T> =
  | { kind: "idle" }
  | { kind: "saved" }
  | { kind: "error"; message: string }
  | { kind: "conflict"; latest: T };

const workflowStatuses: WorkflowStatus[] = ["pending", "completed", "archived"];

export function toContentDraft(content: Content): VersionedContentDraft {
  return { version: content.version, title: content.title ?? "", user_note: content.user_note ?? "", workflow_status: content.workflow_status };
}

export function rebaseContentDraft(base: ContentDraft, draft: ContentDraft, latest: ContentDraft): ContentDraft {
  return {
    title: draft.title === base.title ? latest.title : draft.title,
    user_note: draft.user_note === base.user_note ? latest.user_note : draft.user_note,
    workflow_status: draft.workflow_status === base.workflow_status ? latest.workflow_status : draft.workflow_status,
  };
}

function readVersion(form: FormData): number {
  const version = Number(form.get("expected_version"));
  if (!Number.isSafeInteger(version) || version < 1) throw new Error("편집 버전이 올바르지 않아요.");
  return version;
}

function readOptionalText(form: FormData, field: string, max: number): string | null | undefined {
  const value = form.get(field);
  if (value === null) return undefined;
  if (typeof value !== "string" || Array.from(value).length > max) throw new Error(`입력은 ${max.toLocaleString("ko-KR")}자 이하로 작성해 주세요.`);
  return value.trim() ? value : null;
}

export function readContentPatch(form: FormData): ContentPatch {
  const patch: ContentPatch = { expected_version: readVersion(form) };
  const title = readOptionalText(form, "title", 500);
  const note = readOptionalText(form, "user_note", 10000);
  const workflow = form.get("workflow_status");
  if (title !== undefined) patch.title = title;
  if (note !== undefined) patch.user_note = note;
  if (workflow !== null) {
    const status = workflowStatuses.find((status) => status === workflow);
    if (!status) throw new Error("보관 상태를 다시 선택해 주세요.");
    patch.workflow_status = status;
  }
  return patch;
}

export function readRecommendationPatch(form: FormData): RecommendationPatch {
  const userText = readOptionalText(form, "user_text", 10000);
  if (userText === undefined) throw new Error("추천 수정 내용을 입력해 주세요.");
  return { expected_version: readVersion(form), user_text: userText };
}
