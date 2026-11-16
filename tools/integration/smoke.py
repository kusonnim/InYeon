"""Two-account I1 API smoke. It leaves one synthetic text item per run."""

import sys
from urllib.parse import urlencode
from uuid import uuid4

from common import (
    Auth, Blocked, CheckError, FIXTURE_USERS, Report, account, api_base, expect,
    parser, process_health, request, require, uuid_field,
)


def positive_int(value):
    return type(value) is int and value >= 1


def page_url(path, cursor, limit):
    query = {"limit": limit}
    if cursor is not None:
        query["cursor"] = cursor
    return f"{path}?{urlencode(query)}"


def api_json(base, path, token, status=200, **kwargs):
    return expect(request(base, path, token=token, **kwargs), status).json()


def scan_catalog(base, token, owner, marker, identifier):
    cursor, seen, matching = None, set(), []
    for _ in range(100):
        page = api_json(base, page_url("/v1/contents", cursor, 20), token)
        items = page.get("items")
        require(isinstance(items, list) and "next_cursor" in page, "Invalid catalog page.")
        for item in items:
            require(isinstance(item, dict) and uuid_field(item.get("user_id"), "catalog owner") == owner,
                    "Catalog returned another owner's content.")
            item_id = uuid_field(item.get("id"), "catalog content ID")
            if item_id == identifier or item.get("source_text") == marker:
                matching.append(item_id)
        cursor = page["next_cursor"]
        if cursor is None:
            return matching
        require(isinstance(cursor, str) and cursor and cursor not in seen, "Catalog cursor did not advance.")
        seen.add(cursor)
    raise Blocked("Catalog exceeded 100 pages. Use a fresh disposable account.")


def scan_sync(base, token, cursor=None, identifier=None):
    seen, previous, updates = {cursor}, (0, ""), []
    for _ in range(100):
        page = api_json(base, page_url("/v1/sync", cursor, 100), token)
        events, next_cursor, has_more = page.get("events"), page.get("next_cursor"), page.get("has_more")
        require(isinstance(events, list) and isinstance(next_cursor, str) and next_cursor
                and type(has_more) is bool, "Invalid sync page.")
        for event in events:
            require(isinstance(event, dict), "Invalid sync event.")
            sequence = event.get("sequence")
            require(isinstance(sequence, str) and sequence.isascii() and sequence.isdecimal(),
                    "Sync sequence must be a decimal string.")
            digits = sequence.lstrip("0") or "0"
            current = (len(digits), digits)
            require(current > previous, "Sync events are outside commit order or repeated within the scan.")
            previous = current
            if (identifier and event.get("entity_type") == "content" and event.get("operation") == "upsert"
                    and uuid_field(event.get("entity_id"), "sync entity ID") == identifier):
                require(uuid_field(event.get("content_id"), "sync parent ID") == identifier,
                        "Sync content event has a different parent.")
                updates.append(sequence)
        if not has_more:
            return next_cursor, updates
        require(next_cursor not in seen, "Sync cursor did not advance.")
        seen.add(next_cursor)
        cursor = next_cursor
    raise Blocked("Sync exceeded 100 pages. Use a fresh disposable account.")


def check_content(item, owner, marker, identifier):
    require(uuid_field(item.get("id"), "content ID") == identifier
            and uuid_field(item.get("user_id"), "content owner") == owner, "Content identity changed.")
    require(item.get("input_type") == "text" and item.get("source_text") == marker
            and "source_url" in item and item["source_url"] is None and item.get("asset_ids") == [],
            "Original source did not round-trip.")
    require("title" in item and "user_note" in item and item["user_note"] is None
            and positive_int(item.get("version")), "Invalid editable fields or version.")
    require(item.get("workflow_status") == "pending" and item.get("analysis_status") in
            ("pending", "processing", "completed", "partial", "failed"), "Unexpected workflow or analysis state.")
    require("analysis" in item and (item["analysis"] is None or isinstance(item["analysis"], dict))
            and isinstance(item.get("recommendations"), list), "Invalid analysis or recommendations fields.")
    notice = item.get("notification")
    require(isinstance(notice, dict) and uuid_field(notice.get("content_id"), "notification parent ID") == identifier
            and notice.get("visibility") == "active" and notice.get("generation") == 1
            and positive_int(notice.get("revision")), "Unexpected initial notification generation or visibility.")


def edit_title(base, path, token, before, title, check):
    original_title = before["title"]
    for _ in range(3):
        reply = request(base, path, token=token, method="PATCH",
                        body={"expected_version": before["version"], "title": title})
        if reply.status != 409:
            edited = expect(reply, 200).json()
            check(edited)
            require(edited["title"] == title and edited["version"] > before["version"],
                    "Edit did not update title and advance version.")
            return before["version"], edited
        error = expect(reply, 409, "version_conflict")
        require(positive_int(error.get("current_version")) and error["current_version"] > before["version"],
                "Version conflict did not return a newer version.")
        before = api_json(base, path, token)
        check(before)
        require(before["title"] == original_title, "Another editor changed the title of the smoke item.")
    raise Blocked("The smoke item kept changing during edit. Retry with a quiet disposable account.")


def run(args, report):
    staging = args.profile == "staging"
    with report.step("Profile configuration", "Disposable staging" if staging else "Synthetic FastAPI fixture"):
        base = api_base(args.profile, args.api_url)
        require(not args.restart_check or staging, "Restart persistence can only be checked in staging.")
        if args.restart_check and not sys.stdin.isatty():
            raise Blocked("Use an interactive shell for --restart-check.")
        if staging:
            auth = Auth.from_environment()
            login_a, login_b = account("A"), account("B")
            require(login_a[0].casefold() != login_b[0].casefold(), "Supply two distinct disposable accounts.")

    with report.step("GET /health", "Process profile confirmed"):
        process_health(base, args.profile)
    with report.step("Authentication", "Supabase password sessions" if staging else "Synthetic fixture identities"):
        if staging:
            owner, token = auth.sign_in(*login_a)
            owner_b, token_b = auth.sign_in(*login_b)
        else:
            owner, token = FIXTURE_USERS["A"]
            owner_b, token_b = FIXTURE_USERS["B"]
        require(owner != owner_b, "The two sessions resolve to the same owner.")

    with report.step("Authenticated catalog and sync baseline", "Account A checkpoint and valid account B API access"):
        for session_owner, session_token in ((owner, token), (owner_b, token_b)):
            page = api_json(base, "/v1/contents?limit=1", session_token)
            items = page.get("items")
            require(isinstance(items, list) and all(isinstance(item, dict)
                    and uuid_field(item.get("user_id"), "catalog owner") == session_owner for item in items),
                    "Catalog unavailable or returned a foreign owner.")
        baseline, _ = scan_sync(base, token)

    marker = f"ITDA I1 synthetic smoke {uuid4()}"
    print(f"Synthetic run marker | {marker}", flush=True)
    body = {"input_type": "text", "source_text": marker, "asset_ids": []}
    key = str(uuid4())

    def create(access_token):
        return api_json(base, "/v1/contents", access_token, 201, method="POST", body=body, idempotency=key)

    with report.step("POST /v1/contents", "201 with source, pending analysis/workflow, and initial notification"):
        receipt = create(token)
        identifier = uuid_field(receipt.get("id"), "content ID")
        check_content(receipt, owner, marker, identifier)
        require(receipt["analysis_status"] == "pending" and receipt["analysis"] is None
                and receipt["recommendations"] == [] and receipt["notification"]["revision"] == 1
                and receipt["version"] == 1 and receipt["title"] is None, "Unexpected initial receipt state.")

    path = f"/v1/contents/{identifier}"

    def check(item):
        check_content(item, owner, marker, identifier)

    with report.step("Read acknowledgment", "Independent GET returned the source and owner" if staging
                     else "Independent GET returned the in-memory receipt"):
        before = api_json(base, path, token)
        check(before)

    with report.step("Idempotency replay and duplicate check", "Original 201 and exactly one matching catalog item"):
        require(create(token) == receipt, "Replay differed from the original receipt.")
        expect(request(base, "/v1/contents", token=token, method="POST", idempotency=key,
                       body={**body, "source_text": marker + " changed"}), 409, "idempotency_conflict")
        require(scan_catalog(base, token, owner, marker, identifier) == [identifier],
                "Catalog is missing the receipt or contains a duplicate.")

    with report.step("Creation sync event", "Content upsert after the original cursor"):
        after_create, creates = scan_sync(base, token, baseline, identifier)
        require(creates, "The new content is absent from sync.")

    title = f"{marker} edited"
    with report.step("Versioned title edit and readback", "Title persisted, source and independent states preserved"):
        old_version, edited = edit_title(base, path, token, before, title, check)
        saved = api_json(base, path, token)
        check(saved)
        require(saved["title"] == title and saved["version"] >= edited["version"], "Edit did not survive readback.")
        stale = expect(request(base, path, token=token, method="PATCH",
                               body={"expected_version": old_version, "title": title}), 409, "version_conflict")
        require(positive_int(stale.get("current_version")) and stale["current_version"] >= saved["version"],
                "Stale edit did not return the current version.")

    with report.step("Edit sync event", "New content upsert and replay from the same opaque cursor"):
        _, updates = scan_sync(base, token, after_create, identifier)
        require(updates, "Title edit is absent from sync.")
        _, replayed = scan_sync(base, token, after_create, identifier)
        require(replayed[:len(updates)] == updates, "Replaying the edit cursor changed the content event sequence.")

    with report.step("Account B isolation", "404 not_found for A's content and 400 invalid_cursor for A's cursor"):
        expect(request(base, path, token=token_b), 404, "not_found")
        expect(request(base, page_url("/v1/sync", after_create, 1), token=token_b), 400, "invalid_cursor")
        require(scan_catalog(base, token_b, owner_b, marker, identifier) == [], "Account B can list account A's item.")

    if args.restart_check:
        with report.step("API process restart persistence", "Edited item and receipt survived the operator-confirmed restart"):
            try:
                input("Restart only the approved disposable staging API process, then press Enter when it is ready. ")
            except EOFError:
                raise Blocked("Process restart confirmation was unavailable.") from None
            process_health(base, args.profile)
            restarted_owner, token = auth.sign_in(*login_a)
            require(restarted_owner == owner, "Account A resolved to a different owner after restart.")
            saved = api_json(base, path, token)
            check(saved)
            require(saved["title"] == title and saved["version"] >= edited["version"], "Edit lost after restart.")
            require(create(token) == receipt, "Idempotency receipt changed after restart.")
            require(scan_catalog(base, token, owner, marker, identifier) == [identifier], "Duplicate after restart.")
    else:
        report.add("NOT TESTED", "API process restart persistence", "Optional in the staging profile.")


def main():
    command = parser(__doc__)
    command.add_argument("--restart-check", action="store_true", help="Pause for an operator-managed staging API restart.")
    report = Report()
    try:
        run(command.parse_args(), report)
    except CheckError:
        report.add("NOT TESTED", "Remaining smoke steps", "Resolve the preceding result and rerun.")
    return report.exit_code()


if __name__ == "__main__":
    sys.exit(main())
