"""Deterministic I1 analysis checks. No model provider is called."""

from html.parser import HTMLParser
import json
import os
from types import SimpleNamespace
from uuid import uuid4

from fastapi.testclient import TestClient
import pytest

from app.config import Settings
from app.main import create_app
from app.models import Content
from common import ROOT, base_url, expect, request
from worker.pipeline import ExtractedSource, analyze


CATALOG = json.loads((ROOT / "contracts/examples/catalog.json").read_text(encoding="utf-8"))["items"]
CASES = {"recommended": CATALOG[0], "zero": CATALOG[2], "partial": CATALOG[4], "failed": CATALOG[1]}


@pytest.mark.parametrize("case", CASES)
def test_synthetic_analysis_round_trip(case):
    app = create_app(Settings(mode="fixture", environment="test"), seed=False)
    template = Content.model_validate(CASES[case])
    source_body = template.model_dump(mode="json", include={"input_type", "source_text", "source_url"})
    with TestClient(app) as client:
        auth = {"Authorization": "Bearer fixture-user-a"}
        receipt = client.post("/v1/contents", headers={**auth, "Idempotency-Key": str(uuid4())},
                              json=source_body)
        assert receipt.status_code == 201
        item = Content.model_validate(receipt.json())
        assert item.analysis_status == "pending"
        path = f"/v1/contents/{item.id}"
        edit = client.patch(path, headers=auth, json={
            "expected_version": item.version, "title": "Synthetic I1 edit", "workflow_status": "completed",
        })
        assert edit.status_code == 200
        dismissal = client.post("/v1/notification-events", headers={**auth, "Idempotency-Key": str(uuid4())},
                                json={"content_id": str(item.id), "event_type": "dismissed",
                                      "generation": item.notification.generation,
                                      "expected_revision": item.notification.revision})
        assert dismissal.status_code == 200
        baseline = client.get("/v1/sync", headers=auth)
        assert baseline.status_code == 200

        if case == "failed":
            def fail_extraction(_):
                raise ValueError("Synthetic source unavailable")

            extract = SimpleNamespace(extract=fail_extraction)
            summarize = SimpleNamespace(summarize=lambda *_: pytest.fail("Summarization must follow extraction"))
            with pytest.raises(ValueError, match="Synthetic source unavailable"):
                analyze(item, extract, summarize, None)
            status, analysis, recommendations = "failed", None, []
        else:
            status = template.analysis_status
            source = ExtractedSource(text=template.source_text or "", coverage=template.analysis.coverage,
                                     references=(), limitations=tuple(template.analysis.limitations))
            analysis, suggestions = analyze(
                item, SimpleNamespace(extract=lambda _: source),
                SimpleNamespace(summarize=lambda identifier, _: template.analysis.model_copy(
                    update={"content_id": identifier})),
                SimpleNamespace(recommend=lambda identifier, *_: [suggestion.model_copy(update={"content_id": identifier})
                                                                  for suggestion in template.recommendations]),
            )
            recommendations = [suggestion.model_dump(mode="json") for suggestion in suggestions]
            analysis = analysis.model_dump(mode="json")

        # Fixture result writer only. The production AnalysisPersistence adapter is pending.
        app.state.repository.apply_analysis(item.user_id, item.id, analysis, recommendations, status)
        result = client.get(path, headers=auth)
        assert result.status_code == 200
        value = result.json()
        assert value["analysis_status"] == status
        assert value["analysis"] == analysis
        assert value["recommendations"] == recommendations
        assert all(not suggestion["accepted"] and suggestion["user_text"] is None for suggestion in recommendations)
        assert {name: value[name] for name in source_body} == source_body
        assert value["title"] == "Synthetic I1 edit"
        assert value["version"] > edit.json()["version"]
        assert value["workflow_status"] == "completed"
        assert value["notification"] == dismissal.json()["state"]
        sync = client.get("/v1/sync", params={"cursor": baseline.json()["next_cursor"]}, headers=auth)
        assert sync.status_code == 200
        assert [(event["entity_type"], event["content_id"], event["operation"]) for event in sync.json()["events"]] == [
            ("content", str(item.id), "upsert"),
        ]


class VisibleText(HTMLParser):
    """Exclude Next.js hydration scripts from the rendered-text assertions."""

    def __init__(self):
        super().__init__()
        self.hidden = False
        self.parts = []

    def handle_starttag(self, tag, attrs):
        if tag in ("script", "style"):
            self.hidden = True

    def handle_endtag(self, tag):
        if tag in ("script", "style"):
            self.hidden = False

    def handle_data(self, data):
        if not self.hidden:
            self.parts.append(data)


@pytest.mark.parametrize("case", CASES)
def test_synthetic_web_presentation(case):
    base = os.getenv("ITDA_I1_WEB_PREVIEW_URL")
    if not base:
        pytest.skip("Set ITDA_I1_WEB_PREVIEW_URL to the running loopback fixture web app")
    if case == "failed" and os.getenv("ITDA_I1_WEB_FAILED_FIXTURE") != "1":
        pytest.skip("The failed case uses the disposable catalog copy from the I1 runbook")
    template = CASES[case]
    base = base_url(base, allow_local_http=True, local_only=True)
    reply = expect(request(base, f"/contents/{template['id']}"), 200)
    assert reply.headers.get_content_type() == "text/html"
    parser = VisibleText()
    parser.feed(reply.body.decode("utf-8"))
    visible = " ".join(" ".join(parser.parts).split())

    if case == "failed":
        expected = ["확인 가능한 요약이 없어요.", "표시할 추천이 없어요.", template["source_text"]]
    else:
        expected = [template["analysis"]["summary"], *template["analysis"]["limitations"]]
        expected += [suggestion["text"] for suggestion in template["recommendations"]] or ["표시할 추천이 없어요."]
    for value in expected:
        assert " ".join(value.split()) in visible
