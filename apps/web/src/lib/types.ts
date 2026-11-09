/** Mirrors contracts/openapi.yaml. Update contract, clients, fixtures and checks together. */
export type AnalysisStatus = "pending" | "processing" | "completed" | "partial" | "failed";
export type WorkflowStatus = "pending" | "completed" | "archived";
export type RecommendationKind = "action" | "information" | "resource";
export type AnalysisCoverage = "full_text" | "partial_text" | "metadata_only" | "unsupported";

export interface Analysis {
  id: string;
  content_id: string;
  coverage: AnalysisCoverage;
  summary: string | null;
  limitations: string[];
  created_at: string;
}
export interface Recommendation {
  id: string;
  content_id: string;
  kind: RecommendationKind;
  text: string;
  source_url: string | null;
  user_text: string | null;
  accepted: boolean;
  version: number;
  created_at: string;
  updated_at: string;
}
export interface NotificationState {
  content_id: string;
  visibility: "active" | "dismissed";
  generation: number;
  revision: number;
  updated_at: string;
}
export interface Content {
  id: string;
  user_id: string;
  input_type: "text" | "url" | "image" | "document";
  source_text: string | null;
  source_url: string | null;
  asset_ids: string[];
  title: string | null;
  user_note: string | null;
  analysis_status: AnalysisStatus;
  workflow_status: WorkflowStatus;
  version: number;
  created_at: string;
  updated_at: string;
  analysis: Analysis | null;
  recommendations: Recommendation[];
  notification: NotificationState;
}
export interface ContentPage { items: Content[]; next_cursor: string | null }
export interface ContentPatch {
  expected_version: number;
  title?: string | null;
  user_note?: string | null;
  workflow_status?: WorkflowStatus;
}
export interface ApiErrorBody {
  error: { code: string; message: string; request_id: string; current_version?: number | null; current_generation?: number | null; current_revision?: number | null };
}
