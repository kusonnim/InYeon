import assert from "node:assert/strict";
import test from "node:test";
import { HttpContentApi } from "../src/lib/api.ts";

test("HTTP adapter refuses to send unauthenticated user-data requests", async () => {
  const api = new HttpContentApi("https://api.invalid", async () => "");
  await assert.rejects(api.listContents(), /authenticated user session/);
});

test("HTTP adapter transmits version precondition and Bearer token", async () => {
  const previousFetch = globalThis.fetch;
  let capturedUrl = "";
  let capturedInit: RequestInit | undefined;
  globalThis.fetch = async (input, init) => {
    capturedUrl = String(input);
    capturedInit = init;
    return new Response(JSON.stringify({ id: "test-content", version: 8 }), { status: 200 });
  };
  try {
    const api = new HttpContentApi("https://api.invalid/", async () => "test-session-token");
    await api.updateContent("test-content", { expected_version: 7, workflow_status: "archived" });
    assert.equal(capturedUrl, "https://api.invalid/v1/contents/test-content");
    assert.equal(new Headers(capturedInit?.headers).get("Authorization"), "Bearer test-session-token");
    assert.deepEqual(JSON.parse(String(capturedInit?.body)), { expected_version: 7, workflow_status: "archived" });
    assert.equal(capturedInit?.cache, "no-store");
  } finally { globalThis.fetch = previousFetch; }
});
