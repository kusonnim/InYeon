"use server";

import { revalidatePath } from "next/cache";
import { ApiError } from "@/lib/api";
import { getDataMode } from "@/lib/config";
import { readContentPatch, readRecommendationPatch, toContentDraft, type EditResult, type VersionedContentDraft, type VersionedRecommendationDraft } from "@/lib/content-edit";
import { createServerContentApi } from "@/lib/server-api";

const saveError = { kind: "error", message: "저장하지 못했어요. 연결을 확인하고 다시 시도해 주세요." } as const;
const fixtureError = { kind: "error", message: "샘플 모드에서는 수정 내용을 저장할 수 없어요." } as const;
const unavailable = { kind: "error", message: "이 항목을 더 이상 불러올 수 없어요." } as const;

function isConflict(error: unknown): boolean {
  return error instanceof ApiError && error.status === 409 && error.body.error.code === "version_conflict";
}

function refreshContent(id: string) {
  revalidatePath("/");
  revalidatePath(`/contents/${encodeURIComponent(id)}`);
}

export async function saveContent(
  id: string, _previous: EditResult<VersionedContentDraft>, form: FormData,
): Promise<EditResult<VersionedContentDraft>> {
  if (getDataMode() !== "api") return fixtureError;
  let patch;
  try {
    patch = readContentPatch(form);
  } catch (error) {
    return error instanceof Error ? { kind: "error", message: error.message } : saveError;
  }
  if (Object.keys(patch).length === 1) return { kind: "error", message: "변경할 내용을 입력해 주세요." };

  const api = await createServerContentApi();
  try {
    await api.updateContent(id, patch);
  } catch (error) {
    if (error instanceof ApiError && error.status === 404) return unavailable;
    if (!isConflict(error)) return saveError;
    try {
      return { kind: "conflict", latest: toContentDraft(await api.getContent(id)) };
    } catch (readError) {
      return readError instanceof ApiError && readError.status === 404 ? unavailable : saveError;
    }
  }
  refreshContent(id);
  return { kind: "saved" };
}

export async function saveRecommendation(
  contentId: string, id: string, _previous: EditResult<VersionedRecommendationDraft>, form: FormData,
): Promise<EditResult<VersionedRecommendationDraft>> {
  if (getDataMode() !== "api") return fixtureError;
  let patch;
  try {
    patch = readRecommendationPatch(form);
  } catch (error) {
    return error instanceof Error ? { kind: "error", message: error.message } : saveError;
  }

  const api = await createServerContentApi();
  try {
    await api.updateRecommendation(id, patch);
  } catch (error) {
    if (error instanceof ApiError && error.status === 404) return unavailable;
    if (!isConflict(error)) return saveError;
    try {
      const content = await api.getContent(contentId);
      const latest = content.recommendations.find((item) => item.id === id);
      return latest ? { kind: "conflict", latest: { user_text: latest.user_text ?? "", version: latest.version } } : unavailable;
    } catch (readError) {
      return readError instanceof ApiError && readError.status === 404 ? unavailable : saveError;
    }
  }
  refreshContent(contentId);
  return { kind: "saved" };
}
