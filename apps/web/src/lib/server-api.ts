import { FixtureContentApi } from "./fixture-api";
import type { ContentApi } from "./api";

export function createServerContentApi(): ContentApi {
  const mode = process.env.ITDA_DATA_MODE ?? "fixture";
  if (mode !== "fixture") {
    throw new Error("Real API mode requires a Supabase session/token provider. Implement it before enabling API mode.");
  }
  return new FixtureContentApi();
}
