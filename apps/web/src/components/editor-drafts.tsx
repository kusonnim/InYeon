"use client";

import { createContext, useContext, useState, type ReactNode } from "react";
import type { VersionedContentDraft, VersionedRecommendationDraft } from "@/lib/content-edit";

export interface ContentEditDraft {
  base: VersionedContentDraft;
  values: VersionedContentDraft;
}
export interface RecommendationEditDraft {
  base: VersionedRecommendationDraft;
  value: string;
}

interface DraftStore {
  contents: Record<string, ContentEditDraft>;
  recommendations: Record<string, RecommendationEditDraft>;
  setContent: (id: string, draft: ContentEditDraft | null) => void;
  setRecommendation: (id: string, draft: RecommendationEditDraft | null) => void;
}

const EditorDrafts = createContext<DraftStore | null>(null);

/** Lives above the page error boundary. The layout key resets memory on account changes. */
export function EditorDraftProvider({ children }: { children: ReactNode }) {
  const [contents, setContents] = useState<Record<string, ContentEditDraft>>({});
  const [recommendations, setRecommendations] = useState<Record<string, RecommendationEditDraft>>({});

  function setContent(id: string, draft: ContentEditDraft | null) {
    setContents((current) => {
      const next = { ...current };
      if (draft) next[id] = draft;
      else delete next[id];
      return next;
    });
  }

  function setRecommendation(id: string, draft: RecommendationEditDraft | null) {
    setRecommendations((current) => {
      const next = { ...current };
      if (draft) next[id] = draft;
      else delete next[id];
      return next;
    });
  }

  return <EditorDrafts.Provider value={{ contents, recommendations, setContent, setRecommendation }}>
    {children}
  </EditorDrafts.Provider>;
}

export function useEditorDrafts() {
  const store = useContext(EditorDrafts);
  if (!store) throw new Error("An editor requires EditorDraftProvider.");
  return store;
}
