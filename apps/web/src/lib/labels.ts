import type {
  AnalysisCoverage,
  AnalysisStatus,
  Content,
  NotificationState,
  RecommendationKind,
  WorkflowStatus,
} from "./types";

export const analysisStatusLabels: Record<AnalysisStatus, string> = {
  pending: "대기 중",
  processing: "분석 중",
  completed: "완료",
  partial: "일부 완료",
  failed: "실패",
};

export const workflowStatusLabels: Record<WorkflowStatus, string> = {
  pending: "미완료",
  completed: "완료",
  archived: "보관됨",
};

export const notificationLabels: Record<NotificationState["visibility"], string> = {
  active: "활성",
  dismissed: "닫힘",
};

export const inputTypeLabels: Record<Content["input_type"], string> = {
  text: "텍스트",
  url: "링크",
  image: "이미지",
  document: "문서",
};

export const recommendationKindLabels: Record<RecommendationKind, string> = {
  action: "행동",
  information: "정보",
  resource: "자료",
};

export const coverageLabels: Record<AnalysisCoverage, string> = {
  full_text: "전체 본문",
  partial_text: "일부 본문",
  metadata_only: "메타데이터만",
  unsupported: "분석할 수 없는 원본",
};
