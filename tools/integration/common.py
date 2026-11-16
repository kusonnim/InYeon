"""Shared, redacted HTTP checks for the I1 Windows runbook."""

import argparse
from contextlib import contextmanager
from dataclasses import dataclass
from email.message import Message
from http.client import HTTPException
import json
import os
from pathlib import Path
import re
from urllib.error import HTTPError
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, ProxyHandler, Request, build_opener
from uuid import UUID


ROOT = Path(__file__).resolve().parents[2]
LOOPBACK = {"localhost", "127.0.0.1", "::1"}
STAGING_API = "ITDA_STAGING_API_BASE_URL"
STAGING_AUTH = "ITDA_STAGING_SUPABASE_URL"
STAGING_KEY = "ITDA_STAGING_SUPABASE_PUBLISHABLE_KEY"
FIXTURE_USERS = {
    "A": ("00000000-0000-4000-8000-000000000001", "fixture-user-a"),
    "B": ("00000000-0000-4000-8000-000000000002", "fixture-user-b"),
}


class CheckError(Exception):
    outcome = "FAIL"


class Blocked(CheckError):
    outcome = "BLOCKED"


class Report:
    def __init__(self):
        self.outcomes = set()

    def add(self, outcome, check, detail=""):
        self.outcomes.add(outcome)
        print(f"{outcome:10} {check}" + (f" | {detail}" if detail else ""), flush=True)

    @contextmanager
    def step(self, name, detail=""):
        try:
            yield
        except CheckError as error:
            self.add(error.outcome, name, str(error))
            raise
        else:
            self.add("PASS", name, detail)

    def attempt(self, name, check, detail=""):
        try:
            with self.step(name, detail):
                return check()
        except CheckError:
            return None

    def exit_code(self):
        if "FAIL" in self.outcomes:
            return 1
        return 2 if "BLOCKED" in self.outcomes else 0


def require(condition, message):
    if not condition:
        raise CheckError(message)


def setting(name):
    value = os.environ.get(name, "")
    if not value.strip():
        raise Blocked(f"Set {name} in this shell.")
    return value


def base_url(value, *, local_hosts=LOOPBACK, allow_local_http=False, local_only=False):
    message = "Use an absolute base URL with the required transport and no credentials, query, or fragment."
    try:
        parts = urlsplit(value)
        host, port = parts.hostname, parts.port
    except ValueError:
        raise CheckError(message) from None
    require(host and port != 0 and not any(char.isspace() or ord(char) < 32 for char in value)
            and not any(char in value for char in "?#\\") and parts.username is None,
            message)
    require(parts.scheme == "https" or (allow_local_http and host in local_hosts and parts.scheme == "http"),
            message)
    require(not local_only or host in local_hosts, "Synthetic services must use loopback.")
    return value.rstrip("/")


def publishable_key(value):
    require(re.fullmatch(r"sb_publishable_[A-Za-z0-9_-]+", value), "Supply a Supabase publishable key.")
    return value


def parser(description):
    command = argparse.ArgumentParser(description=description)
    command.add_argument("--profile", choices=("fixture", "staging"), required=True)
    command.add_argument("--api-url", help="Override the local fixture API base URL (default http://127.0.0.1:8000).")
    return command


def api_base(profile, override):
    if profile == "fixture":
        return base_url(override or "http://127.0.0.1:8000", allow_local_http=True, local_only=True)
    require(override is None, f"Use {STAGING_API} so the harness and Android share the staging API base.")
    return base_url(setting(STAGING_API))


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


HTTP = build_opener(ProxyHandler({}), NoRedirect())


@dataclass(frozen=True)
class Reply:
    status: int
    headers: Message
    body: bytes

    def json(self):
        try:
            value = json.loads(self.body)
        except ValueError:
            raise CheckError("Expected a JSON object.") from None
        require(isinstance(value, dict), "Expected a JSON object.")
        return value


def request(base, path, *, method="GET", token=None, key=None, body=None, idempotency=None):
    headers = {}
    if token is not None:
        headers["Authorization"] = f"Bearer {token}"
    if key is not None:
        headers["apikey"] = key
    if idempotency is not None:
        headers["Idempotency-Key"] = idempotency
    data = None
    if body is not None:
        headers["Content-Type"] = "application/json"
        data = json.dumps(body).encode("utf-8")
    limit = 8 * 1024 * 1024
    try:
        try:
            response = HTTP.open(Request(base + path, data, headers, method=method), timeout=15)
        except HTTPError as error:
            response = error
        with response:
            payload = response.read(limit + 1)
            require(len(payload) <= limit, "Response exceeded the check's size limit.")
            return Reply(response.code, response.headers, payload)
    except (OSError, HTTPException, ValueError):
        raise Blocked("HTTP connection failed. Check service startup, network, and TLS.") from None


def expect(reply, status, code=None):
    if reply.status != status:
        if reply.status in (405, 501, 503):
            raise Blocked(f"Required operation unavailable (HTTP {reply.status}).")
        if reply.status == 404:
            try:
                error = reply.json().get("error")
            except CheckError:
                error = None
            if not isinstance(error, dict):
                raise Blocked("Required route unavailable (HTTP 404 without a contract error).")
        raise CheckError(f"Expected HTTP {status}, received HTTP {reply.status}.")
    if code is not None:
        error = reply.json().get("error")
        require(isinstance(error, dict) and error.get("code") == code, f"Expected structured {code}.")
        uuid_field(error.get("request_id"), "error request ID")
        return error
    return reply


def uuid_field(value, field):
    try:
        return str(UUID(value))
    except (TypeError, ValueError, AttributeError):
        raise CheckError(f"Expected a UUID for {field}.") from None


def process_health(base, profile):
    health = expect(request(base, "/health"), 200).json()
    mode = "fixture" if profile == "fixture" else "production"
    require(health.get("status") == "ok" and health.get("mode") == mode,
            "API process health or profile mismatch.")
    persistence = health.get("persistence")
    require(isinstance(persistence, str) and persistence, "API health is missing persistence status.")
    require((persistence == "volatile-memory") == (profile == "fixture"), "API persistence profile mismatch.")
    return persistence


@dataclass(frozen=True)
class Auth:
    base: str
    key: str

    @classmethod
    def from_environment(cls):
        return cls(base_url(setting(STAGING_AUTH)), publishable_key(setting(STAGING_KEY)))

    def sign_in(self, email, password):
        reply = request(self.base, "/auth/v1/token?grant_type=password", method="POST",
                        key=self.key, body={"email": email, "password": password})
        if reply.status in (400, 401, 403, 422, 429):
            raise Blocked(f"Supabase password sign-in returned HTTP {reply.status}. Check the disposable account and Auth settings.")
        session = expect(reply, 200).json()
        token, user = session.get("access_token"), session.get("user")
        require(isinstance(token, str) and re.fullmatch(r"[\w-]+\.[\w-]+\.[\w-]+", token, re.ASCII)
                and isinstance(user, dict), "Supabase Auth did not return a user access JWT.")
        return uuid_field(user.get("id"), "Supabase user ID"), token


def account(label):
    return setting(f"ITDA_SMOKE_{label}_EMAIL").strip(), setting(f"ITDA_SMOKE_{label}_PASSWORD")
