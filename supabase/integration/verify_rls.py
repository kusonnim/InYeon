"""Verify ITDA table access with two real Supabase password sessions.

The private config names existing accounts and seeded fixture rows. This probe
does not provision users, seed tables, or print credentials or response bodies.
"""

import argparse
import base64
import json
from pathlib import Path
import sys
from urllib.parse import urlencode


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools/integration"))
from common import CheckError, Report, base_url, request, require, uuid_field


OWNER_TABLES = (
    "preferences", "contents", "content_assets", "analyses", "recommendations",
    "feedback_events", "notification_states", "sync_events",
)
SERVER_TABLES = ("analysis_jobs", "sync_heads", "idempotency_records", "client_devices")
PRIMARY_KEYS = {
    "preferences": ("user_id",),
    "notification_states": ("content_id",),
    "sync_events": ("user_id", "sequence"),
    "sync_heads": ("user_id",),
    "idempotency_records": ("user_id", "operation", "idempotency_key"),
}


def public_key(value):
    require(isinstance(value, str) and value, "Supply a publishable or legacy anon key.")
    if value.startswith("sb_publishable_"):
        return value
    try:
        payload = value.split(".")[1]
        claims = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
    except (IndexError, ValueError, TypeError):
        raise CheckError("Supply a publishable or legacy anon key.") from None
    require(isinstance(claims, dict) and claims.get("role") == "anon", "The probe requires a client key.")
    return value


def load_config(path, allow_local):
    try:
        config = json.loads(Path(path).read_text(encoding="utf-8"))
        config["url"] = base_url(config["url"], allow_local_http=allow_local)
        config["publishable_key"] = public_key(config["publishable_key"])
        accounts = config["accounts"]
        require(isinstance(accounts, list) and len(accounts) == 2, "Configure exactly two test accounts.")
        for account in accounts:
            account["id"] = uuid_field(account["id"], "test account")
            require(isinstance(account["email"], str) and isinstance(account["password"], str)
                    and account["email"] and account["password"], "Configure test account credentials.")
            rows = account["fixtures"]
            require(isinstance(rows, dict) and set(rows) == set(OWNER_TABLES), "Configure all eight owner table fixtures.")
            server_rows = account.get("server_fixtures", {})
            require(isinstance(server_rows, dict) and set(server_rows) <= set(SERVER_TABLES),
                    "Server fixtures contain an unexpected table.")
            for table, row in (rows | server_rows).items():
                require(isinstance(row, dict) and row.get("user_id") == account["id"],
                        "Each fixture must belong to its configured account.")
                require(all(key in row for key in PRIMARY_KEYS.get(table, ("id",))),
                        "A fixture is missing a primary key.")
        require(accounts[0]["id"] != accounts[1]["id"], "The test accounts must be distinct.")
        return config
    except (OSError, KeyError, TypeError, ValueError):
        raise CheckError("Cannot read the private RLS config or its required fields.") from None


def json_body(reply):
    try:
        return json.loads(reply.body)
    except (ValueError, UnicodeDecodeError):
        raise CheckError("Expected a JSON response.") from None


def deny(reply, authenticated):
    expected = 403 if authenticated else 401
    require(reply.status == expected, f"Expected denied HTTP {expected}, received HTTP {reply.status}.")
    body = json_body(reply)
    require(isinstance(body, dict) and body.get("code") == "42501", "Expected a PostgreSQL permission denial.")


def table_path(table, row):
    keys = PRIMARY_KEYS.get(table, ("id",))
    filters = {key: f"eq.{row[key]}" for key in keys}
    return f"/rest/v1/{table}?{urlencode(filters)}"


class Probe:
    def __init__(self, config):
        self.config = config

    def send(self, path, *, token=None, method="GET", body=None):
        return request(self.config["url"], path, key=self.config["publishable_key"],
                       token=token, method=method, body=body)

    def sign_in(self, account):
        reply = self.send("/auth/v1/token?grant_type=password", method="POST",
                          body={"email": account["email"], "password": account["password"]})
        require(reply.status == 200, f"Password sign-in returned HTTP {reply.status}.")
        session = json_body(reply)
        require(isinstance(session, dict) and isinstance(session.get("access_token"), str)
                and isinstance(session.get("user"), dict) and session["user"].get("id") == account["id"],
                "Auth account identity mismatch.")
        token = session["access_token"]
        verified = self.send("/auth/v1/user", token=token)
        user = json_body(verified)
        require(verified.status == 200 and isinstance(user, dict) and user.get("id") == account["id"],
                "Supabase did not verify the expected account.")
        return token

    def own_row(self, table, row, token):
        reply = self.send(table_path(table, row), token=token)
        require(reply.status == 200, f"Owner read returned HTTP {reply.status}.")
        rows = json_body(reply)
        require(isinstance(rows, list) and len(rows) == 1
                and isinstance(rows[0], dict)
                and all(rows[0].get(key) == value for key, value in row.items()),
                "Owner read did not return the expected fixture.")

    def foreign_row(self, table, row, token):
        reply = self.send(table_path(table, row), token=token)
        require(reply.status == 200 and json_body(reply) == [], "A foreign fixture was visible.")

    def writes_denied(self, table, row, token):
        path = table_path(table, row)
        for method, target, body in (
            ("POST", f"/rest/v1/{table}", row),
            ("PATCH", path, {"user_id": row["user_id"]}),
            ("DELETE", path, None),
        ):
            deny(self.send(target, token=token, method=method, body=body), authenticated=True)

    def rpc_denied(self, account, token):
        owner = account["id"]
        content = account["fixtures"]["contents"]["id"]
        calls = {
            "lock_sync_head": {"p_user_id": owner},
            "append_sync_event": {"p_user_id": owner, "p_entity_type": "content",
                                  "p_entity_id": content, "p_operation": "upsert", "p_content_id": content},
            "dismiss_notification": {"p_user_id": owner, "p_content_id": content,
                                     "p_generation": 1, "p_expected_revision": 1},
            "restore_notification": {"p_user_id": owner, "p_content_id": content,
                                     "p_expected_generation": 1, "p_expected_revision": 1},
        }
        for name, body in calls.items():
            deny(self.send(f"/rest/v1/rpc/{name}", token=token, method="POST", body=body),
                 authenticated=token is not None)


def run(config, report):
    probe = Probe(config)
    accounts = config["accounts"]
    sessions = [report.attempt(f"Account {label} real Auth session", lambda account=account: probe.sign_in(account))
                for label, account in zip(("A", "B"), accounts)]
    if any(token is None for token in sessions):
        return report.exit_code()
    for index, (account, token) in enumerate(zip(accounts, sessions)):
        label = "AB"[index]
        for table in OWNER_TABLES:
            own = account["fixtures"][table]
            foreign = accounts[1 - index]["fixtures"][table]
            report.attempt(f"{label} {table} owner read", lambda: probe.own_row(table, own, token))
            report.attempt(f"{label} {table} foreign row hidden", lambda: probe.foreign_row(table, foreign, token))
            report.attempt(f"{label} {table} anonymous read denied",
                           lambda: deny(probe.send(table_path(table, own)), authenticated=False))
            report.attempt(f"{label} {table} direct writes denied", lambda: probe.writes_denied(table, own, token))
        for table in SERVER_TABLES:
            report.attempt(f"{label} {table} server-only read",
                           lambda: deny(probe.send(f"/rest/v1/{table}?select=*&limit=1", token=token), authenticated=True))
            if table in account.get("server_fixtures", {}):
                row = account["server_fixtures"][table]
                report.attempt(f"{label} {table} direct writes denied", lambda: probe.writes_denied(table, row, token))
        report.attempt(f"{label} server RPC denied", lambda: probe.rpc_denied(account, token))
        report.attempt(f"{label} anonymous RPC denied", lambda: probe.rpc_denied(account, None))
    return report.exit_code()


def main():
    command = argparse.ArgumentParser(description=__doc__)
    command.add_argument("--config", required=True, help="Private JSON account and fixture manifest.")
    command.add_argument("--allow-local", action="store_true", help="Allow a disposable HTTP loopback stack.")
    args = command.parse_args()
    report = Report()
    try:
        config = load_config(args.config, args.allow_local)
        return run(config, report)
    except CheckError as error:
        report.add(error.outcome, "RLS configuration", str(error))
        return report.exit_code()


if __name__ == "__main__":
    sys.exit(main())
