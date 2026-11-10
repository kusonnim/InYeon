import type { ApiErrorBody, Content, ContentPage, ContentPatch, Recommendation, RecommendationPatch, SyncPage } from "./types.ts";

export interface ContentApi {
  listContents(cursor?: string): Promise<ContentPage>;
  getContent(id: string): Promise<Content>;
  updateContent(id: string, patch: ContentPatch): Promise<Content>;
  updateRecommendation(id: string, patch: RecommendationPatch): Promise<Recommendation>;
  syncChanges(cursor?: string): Promise<SyncPage>;
}
export class ApiError extends Error {
  readonly status: number;
  readonly body: ApiErrorBody;
  constructor(status: number, body: ApiErrorBody) {
    super(body.error.message);
    this.status = status;
    this.body = body;
  }
}
/** Inject a short-lived Supabase access token from the authenticated session, never a service key. */
export class HttpContentApi implements ContentApi {
  private readonly baseUrl: string;
  private readonly accessToken: () => Promise<string>;
  constructor(baseUrl: string, accessToken: () => Promise<string>) {
    this.baseUrl = baseUrl;
    this.accessToken = accessToken;
  }

  private async request<T>(path: string, init?: RequestInit): Promise<T> {
    const token = await this.accessToken();
    if (!token) throw new Error("An authenticated user session is required.");
    const response = await fetch(`${this.baseUrl.replace(/\/$/, "")}${path}`, {
      ...init,
      signal: AbortSignal.timeout(30_000),
      cache: "no-store",
      headers: { ...init?.headers, Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
    });
    if (!response.ok) throw new ApiError(response.status, await response.json() as ApiErrorBody);
    return await response.json() as T;
  }
  listContents(cursor?: string): Promise<ContentPage> {
    return this.request(`/v1/contents${cursor ? `?cursor=${encodeURIComponent(cursor)}` : ""}`);
  }
  getContent(id: string): Promise<Content> {
    return this.request(`/v1/contents/${encodeURIComponent(id)}`);
  }
  updateContent(id: string, patch: ContentPatch): Promise<Content> {
    return this.request(`/v1/contents/${encodeURIComponent(id)}`, { method: "PATCH", body: JSON.stringify(patch) });
  }
  updateRecommendation(id: string, patch: RecommendationPatch): Promise<Recommendation> {
    return this.request(`/v1/recommendations/${encodeURIComponent(id)}`, { method: "PATCH", body: JSON.stringify(patch) });
  }
  syncChanges(cursor?: string): Promise<SyncPage> {
    const params = new URLSearchParams({ limit: "100" });
    if (cursor) params.set("cursor", cursor);
    return this.request(`/v1/sync?${params}`);
  }
}
