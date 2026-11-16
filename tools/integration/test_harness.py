"""Regression checks for the I1 environment and failure gates."""

import base64
import json
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


def token(claims, *, alg="ES256", kid="signing-key"):
    def encode(value):
        return base64.urlsafe_b64encode(json.dumps(value).encode()).decode().rstrip("=")
    return f"{encode({'alg': alg, 'kid': kid})}.{encode(claims)}.synthetic-signature"


@pytest.mark.parametrize("profile", ["c1", "local"])
def test_lab_cannot_send_auth_sessions_to_remote_api(profile):
    with pytest.raises(common.CheckError, match="loopback"):
        common.api_base(profile, "https://api.example.test")


def test_lab_auth_credentials_and_origin_are_profile_scoped(monkeypatch):
    monkeypatch.setenv(common.STAGING_AUTH, "https://other-project.example.test")
    monkeypatch.setenv("ITDA_LAB_STAGING_PUBLIC_KEY", "sb_publishable_c1_example")
    monkeypatch.setenv("ITDA_LAB_LOCAL_PUBLIC_KEY", token({"role": "service_role"}))
    assert common.Auth.from_environment("c1").base == common.LAB_TARGETS["c1"]["auth_url"]
    with pytest.raises(common.CheckError, match="public client key"):
        common.Auth.from_environment("local")
    monkeypatch.setenv("ITDA_LAB_LOCAL_PUBLIC_KEY", token({"role": "anon"}))
    assert common.Auth.from_environment("local").base == "http://127.0.0.1:55421"


@pytest.mark.parametrize("profile", ["c1", "local"])
def test_lab_smoke_stops_before_sign_in_on_scaffold(profile, monkeypatch):
    monkeypatch.setattr(smoke, "process_health", lambda *_: "unconfigured")
    monkeypatch.setattr(smoke.Auth, "from_environment", lambda *_: pytest.fail("Scaffold must stop before sign-in"))
    report = common.Report()
    with pytest.raises(common.Blocked, match="JWT and persistent API adapters"):
        smoke.run(SimpleNamespace(profile=profile, api_url=None, restart_check=False), report)
    assert report.exit_code() == 2


def test_signing_check_requires_fresh_token_metadata_and_auth_confirmation(monkeypatch):
    owner = common.FIXTURE_USERS["A"][0]
    auth = common.Auth("https://auth.example.test", "sb_publishable_example")
    claims = {"iss": auth.base + "/auth/v1", "aud": "authenticated", "sub": owner}
    session_jwt = token(claims)
    monkeypatch.setattr(common, "signing_keys", lambda _: [{"alg": "ES256", "kid": "signing-key", "kty": "EC"}])

    def confirmed(base, path, **options):
        assert base == auth.base and path == "/auth/v1/user"
        assert options == {"key": auth.key, "token": session_jwt}
        return common.Reply(200, {}, json.dumps({"id": owner}).encode())

    monkeypatch.setattr(common, "request", confirmed)
    auth.check_signing_mode([(owner, session_jwt)], "ES256")
    with pytest.raises(common.CheckError, match="algorithm differs"):
        auth.check_signing_mode([(owner, session_jwt)], "HS256")
    with pytest.raises(common.CheckError, match="absent from the Auth JWKS"):
        auth.check_signing_mode([(owner, token(claims, kid="other-key"))], "ES256")
