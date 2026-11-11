"""Regression checks for the I1 environment and failure gates."""

from types import SimpleNamespace

import pytest

import common
import smoke


@pytest.mark.parametrize("url", [
    "https://example.test", "http://localhost@example.test", "http://127.0.0.1?secret=value",
])
def test_fixture_credentials_are_confined_to_loopback(url):
    with pytest.raises(common.CheckError):
        common.api_base("fixture", url)


def test_missing_or_stubbed_route_is_blocked():
    for status in (404, 405, 501, 503):
        with pytest.raises(common.Blocked, match=str(status)):
            common.expect(common.Reply(status, {}, b'{"detail":"Not Found"}'), 200)


def test_staging_requires_both_account_inputs_before_http(monkeypatch, capsys):
    monkeypatch.setenv(common.STAGING_API, "https://api.example.test")
    monkeypatch.setenv(common.STAGING_AUTH, "https://auth.example.test")
    monkeypatch.setenv(common.STAGING_KEY, "sb_publishable_example")
    monkeypatch.setenv("ITDA_SMOKE_A_EMAIL", "a@example.test")
    monkeypatch.setenv("ITDA_SMOKE_A_PASSWORD", "a-disposable-test-value")
    monkeypatch.delenv("ITDA_SMOKE_B_EMAIL", raising=False)
    monkeypatch.setattr(smoke, "process_health", lambda *_: pytest.fail("Missing configuration must stop the smoke"))
    report = common.Report()
    args = SimpleNamespace(profile="staging", api_url=None, restart_check=False)
    with pytest.raises(common.Blocked, match="ITDA_SMOKE_B_EMAIL"):
        smoke.run(args, report)
    assert report.exit_code() == 2
    output = capsys.readouterr().out
    assert "BLOCKED" in output
    assert "example.test" not in output
    assert "a-disposable-test-value" not in output


def test_staging_sign_in_refuses_fixture_tokens(monkeypatch):
    def token_response(base, path, **options):
        assert base == "https://auth.example.test"
        assert path == "/auth/v1/token?grant_type=password"
        assert options["method"] == "POST"
        return common.Reply(200, {}, b'{"access_token":"fixture-user-a","user":{}}')

    monkeypatch.setattr(common, "request", token_response)
    with pytest.raises(common.CheckError, match="user access JWT"):
        common.Auth("https://auth.example.test", "sb_publishable_example").sign_in("a@example.test", "synthetic")
