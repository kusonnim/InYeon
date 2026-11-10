import assert from "node:assert/strict";
import test from "node:test";
import { readContentPatch, readRecommendationPatch, rebaseContentDraft } from "../src/lib/content-edit.ts";

test("send only edited content fields, allowing a deliberate clear", () => {
  const form = new FormData();
  form.set("expected_version", "9");
  form.set("user_note", "");
  form.set("workflow_status", "completed");
  assert.deepEqual(readContentPatch(form), { expected_version: 9, user_note: null, workflow_status: "completed" });
  form.set("title", "😀".repeat(500));
  assert.equal(readContentPatch(form).title, form.get("title"));
  form.set("title", "😀".repeat(501));
  assert.throws(() => readContentPatch(form), /500/);
});

test("preserve edits and incorporate untouched remote values on deliberate rebase", () => {
  const original = { title: "Original", user_note: "Before", workflow_status: "pending" } as const;
  const draft = { ...original, title: "My title" };
  const latest = { ...original, title: "Remote title", user_note: "Other device", workflow_status: "completed" } as const;
  assert.deepEqual(rebaseContentDraft(original, draft, latest), { ...latest, title: "My title" });
});

test("editing recommendation wording does not change acceptance", () => {
  const form = new FormData();
  form.set("expected_version", "3");
  form.set("user_text", "My correction");
  form.set("accepted", "true");
  assert.deepEqual(readRecommendationPatch(form), { expected_version: 3, user_text: "My correction" });
});
