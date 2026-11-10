"""Read-only HTTPS checks for an explicitly selected ITDA staging API."""

import json
import os
import ssl
from http.client import HTTPException
from socket import gaierror
from urllib.error import HTTPError, URLError
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, ProxyHandler, Request, build_opener


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, request, fp, code, msg, headers, new_url):
        return None


def staging_base(value):
    parts = urlsplit(value)
    if (parts.scheme != "https" or not parts.hostname or parts.username is not None
            or any(char in value for char in "?#\\") or any(char.isspace() for char in value)
            or (parts.port is not None and not 1 <= parts.port <= 65535)):
        raise ValueError("An absolute HTTPS base URL is required")
    return value.rstrip("/") + "/"


def probe(opener, base, path, label, headers=None):
    try:
        try:
            response = opener.open(Request(base + path, headers=headers or {}), timeout=10)
        except HTTPError as error:
            response = error
        with response:
            status = response.status
            body = response.read(65537)
    except (OSError, HTTPException, ValueError) as error:
        cause = error.reason if isinstance(error, URLError) else error
        if isinstance(cause, ssl.SSLError):
            kind = "TLS error"
        elif isinstance(cause, gaierror):
            kind = "DNS error"
        else:
            kind = "connection error"
        print(f"{label}: {kind}")
        return None, {}

    print(f"{label}: HTTP {status}")
    try:
        data = json.loads(body) if len(body) <= 65536 else None
    except (ValueError, RecursionError):
        data = None
    return status, data if isinstance(data, dict) else {}


def check(opener, base):
    status, health = probe(opener, base, "health", "Process health")
    persistence = health.get("persistence")
    healthy = (status == 200 and health.get("status") == "ok" and health.get("mode") == "production"
               and isinstance(persistence, str) and persistence not in ("", "volatile-memory"))
    if not healthy:
        print("Process health did not identify a non-fixture API.")
    elif persistence == "unconfigured":
        print("Process health reports unconfigured persistence.")

    gates = (
        ("v1/contents?limit=1", "Catalog without a token", None),
        ("v1/sync?limit=1", "Sync without a token", None),
        ("v1/contents?limit=1", "Catalog with a synthetic invalid token",
         {"Authorization": "Bearer itda-a6-invalid-probe"}),
    )
    denied = True
    for path, label, headers in gates:
        status, data = probe(opener, base, path, label, headers)
        error = data.get("error")
        if status != 401 or not isinstance(error, dict) or error.get("code") != "unauthorized":
            denied = False
            print("Expected structured HTTP 401 unauthorized.")
    if not healthy or not denied:
        return 1
    print("HTTPS and authorization rejection checks passed. Authenticated adapters and database checks remain separate.")
    return 0


def main():
    if os.environ.get("ITDA_UPLOAD_MODE") != "staging":
        print("Select ITDA_UPLOAD_MODE=staging before running the preflight.")
        return 2
    try:
        base = staging_base(os.environ.get("ITDA_STAGING_API_BASE_URL", ""))
    except ValueError:
        print("ITDA_STAGING_API_BASE_URL must be an absolute HTTPS base URL without credentials, a query, or a fragment.")
        return 2
    return check(build_opener(ProxyHandler({}), NoRedirect()), base)


if __name__ == "__main__":
    raise SystemExit(main())
