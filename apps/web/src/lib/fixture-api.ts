import catalog from "../../../../contracts/examples/catalog.json";
import { ApiError, type ContentApi } from "./api.ts";
import type { ApiErrorBody, Content, ContentPage, ContentPatch, Recommendation, RecommendationPatch, SyncPage } from "./types.ts";

function fixtureError(status: number, code: string, message: string, current_version?: number): ApiError {
  const error: ApiErrorBody["error"] = { code, message, request_id: crypto.randomUUID() };
  if (current_version !== undefined) error.current_version = current_version;
  return new ApiError(status, { error });
}

/** Isolated in-memory fixture adapter. No production data or durable changes. */
export class FixtureContentApi implements ContentApi {
  private readonly items = structuredClone(catalog.items) as Content[];

  async listContents(cursor?: string): Promise<ContentPage> {
    if (cursor) throw fixtureError(400, "invalid_cursor", "Fixture catalog has one page.");
    return { items: structuredClone(this.items), next_cursor: null };
  }
  async getContent(id: string): Promise<Content> {
    const content = this.items.find((item) => item.id === id);
    if (!content) throw fixtureError(404, "not_found", "Content not found.");
    return structuredClone(content);
  }
  async updateContent(id: string, patch: ContentPatch): Promise<Content> {
    const content = this.items.find((item) => item.id === id);
    if (!content) throw fixtureError(404, "not_found", "Content not found.");
    if (content.version !== patch.expected_version) {
      throw fixtureError(409, "version_conflict", "Reload before applying your edit.", content.version);
    }
    const { expected_version: _expectedVersion, ...fields } = patch;
    Object.assign(content, fields, { version: content.version + 1, updated_at: new Date().toISOString() });
    return structuredClone(content);
  }
  async updateRecommendation(id: string, patch: RecommendationPatch): Promise<Recommendation> {
    const parent = this.items.find((content) => content.recommendations.some((item) => item.id === id));
    const recommendation = parent?.recommendations.find((item) => item.id === id);
    if (!parent || !recommendation) throw fixtureError(404, "not_found", "Recommendation not found.");
    if (recommendation.version !== patch.expected_version) {
      throw fixtureError(409, "version_conflict", "Reload before applying your edit.", recommendation.version);
    }
    const { expected_version: _expectedVersion, ...fields } = patch;
    const now = new Date().toISOString();
    Object.assign(recommendation, fields, { version: recommendation.version + 1, updated_at: now });
    Object.assign(parent, { version: parent.version + 1, updated_at: now });
    return structuredClone(recommendation);
  }
  async syncChanges(): Promise<SyncPage> {
    throw fixtureError(400, "unsupported", "Fixture preview does not synchronize.");
  }
}
